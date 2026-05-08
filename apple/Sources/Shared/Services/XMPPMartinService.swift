import Foundation
import Combine
@preconcurrency import Martin
@preconcurrency import MartinOMEMO
import Security

struct XMPPTimelineDiagnostics: Sendable {
    let mamQuerySucceeded: Bool
    let mamRawCount: Int
    let mamFilteredCount: Int
    let mamEncryptedCount: Int
    let mamDecodedCount: Int
    let cachedCount: Int
    let usedUnfilteredFallback: Bool
}

actor XMPPMartinService: MatrixService {
    private final class TrixMessageCaptureModule: XmppModuleBase, XmppModule {
        static let ID = "trix-message-capture"

        let criteria = Criteria.name("message", types: [StanzaType.chat, StanzaType.normal, nil])
        let features: [String] = []
        let messagesPublisher = PassthroughSubject<Message, Never>()

        func process(stanza: Stanza) throws {
            guard let message = stanza as? Message else {
                return
            }

            messagesPublisher.send(message)
        }
    }

    private final class MAMArchiveCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [MessageArchiveManagementModule.ArchivedMessageReceived] = []

        func append(_ event: MessageArchiveManagementModule.ArchivedMessageReceived) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [MessageArchiveManagementModule.ArchivedMessageReceived] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private struct CapturedMessage: @unchecked Sendable {
        let message: Message
        let carbonAction: MessageCarbonsModule.Action?
    }

    private final class OneShotVoidContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private struct ArchivedTimelineResult {
        let items: [MatrixTimelineItem]
        let rawCount: Int
        let filteredCount: Int
        let encryptedCount: Int
        let usedUnfilteredFallback: Bool
    }

    private final class TrixMartinRosterStore: RosterStore, @unchecked Sendable {
        typealias RosterItem = RosterItemBase

        private let queue = DispatchQueue(label: "TrixMartinRosterStore")
        private var roster: [JID: RosterItemBase] = [:]
        private var rosterVersion: String?

        func clear(for context: Context) {
            queue.async {
                self.roster.removeAll()
                self.rosterVersion = nil
            }
        }

        func items(for context: Context) -> [RosterItemBase] {
            queue.sync {
                Array(roster.values)
            }
        }

        func item(for context: Context, jid: JID) -> RosterItemBase? {
            queue.sync {
                roster[jid]
            }
        }

        func updateItem(
            for context: Context,
            jid: JID,
            name: String?,
            subscription: RosterItemSubscription,
            groups: [String],
            ask: Bool,
            annotations: [RosterItemAnnotation]
        ) {
            let item = RosterItemBase(
                jid: jid,
                name: name,
                subscription: subscription,
                groups: groups,
                ask: ask,
                annotations: annotations
            )
            queue.async {
                self.roster[jid] = item
            }
        }

        func deleteItem(for context: Context, jid: JID) {
            queue.async {
                self.roster.removeValue(forKey: jid)
            }
        }

        func version(for context: Context) -> String? {
            queue.sync {
                rosterVersion
            }
        }

        func set(version: String?, for context: Context) {
            queue.async {
                self.rosterVersion = version
            }
        }

        func initialize(context: Context) {}

        func deinitialize(context: Context) {}
    }

    private final class Connection: @unchecked Sendable {
        let client: XMPPClient
        let rosterModule: RosterModule
        let vCardModule: VCardTempModule
        let messageCaptureModule: TrixMessageCaptureModule
        let mamModule: MessageArchiveManagementModule
        let carbonsModule: MessageCarbonsModule
        let omemoStack: TrixOMEMOStack
        let createdAt: Date
        var cancellables: Set<AnyCancellable> = []

        init(
            client: XMPPClient,
            rosterModule: RosterModule,
            vCardModule: VCardTempModule,
            messageCaptureModule: TrixMessageCaptureModule,
            mamModule: MessageArchiveManagementModule,
            carbonsModule: MessageCarbonsModule,
            omemoStack: TrixOMEMOStack,
            createdAt: Date = Date()
        ) {
            self.client = client
            self.rosterModule = rosterModule
            self.vCardModule = vCardModule
            self.messageCaptureModule = messageCaptureModule
            self.mamModule = mamModule
            self.carbonsModule = carbonsModule
            self.omemoStack = omemoStack
            self.createdAt = createdAt
        }
    }

    private var connections: [String: Connection] = [:]
    private var timelineHistory: [String: [String: [MatrixTimelineItem]]] = [:]
    private var timelineDiagnostics: [String: [String: XMPPTimelineDiagnostics]] = [:]
    private let timelineCacheStore = TrixTimelineCacheStore()
    private static let maxCachedTimelineItems = 200

    func login(userID: String, password: String, serverURL: URL) async throws -> MatrixSession {
        let jid = try Self.normalizedXMPPJID(userID)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            throw MatrixClientError.invalidCredentials
        }

        let resource = Self.resourceName()
        let connection = try makeConnection(jid: jid, password: password, resource: resource)

        do {
            try await connection.client.loginAndWait()
        } catch {
            throw MatrixClientError.xmppConnectionFailed
        }
        await waitForOMEMOReady(connection: connection)

        let boundResource = connection.client.boundJid?.resource ?? resource
        let session = MatrixSession(
            userID: jid,
            deviceID: boundResource,
            homeserverURL: XMPPClientConfiguration.connectionURL,
            accessToken: password,
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "xmpp-martin",
            createdAt: Date()
        )

        await replaceConnection(connection, for: session)
        try? await connection.carbonsModule.enable()
        try? await publishDirectoryProfileIfNeeded(session: session, connection: connection)
        return session
    }

    func restore(session: MatrixSession) async throws -> MatrixAccount {
        let connection = try await ensureConnection(for: session)
        return MatrixAccount(
            userID: session.userID,
            displayName: Self.displayName(from: session.userID),
            deviceID: connection.client.boundJid?.resource ?? session.deviceID
        )
    }

    func logout(session: MatrixSession) async throws {
        guard let connection = connections.removeValue(forKey: Self.sessionKey(session)) else {
            return
        }

        try? await connection.client.disconnect(force: true)
    }

    func rooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        let connection = try await refreshedRosterConnection(for: session)

        return connection.rosterModule.rosterManager
            .items(for: connection.client)
            .filter { item in
                item.jid.bareJid.domain == XMPPClientConfiguration.serverName
            }
            .map { item in
                let peerJID = item.jid.bareJid.stringValue
                let hasTrustedDevice = connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID)
                return MatrixRoomSummary(
                    id: peerJID,
                    name: item.name ?? Self.displayName(from: peerJID),
                    kind: .direct,
                    isEncrypted: hasTrustedDevice,
                    unreadCount: 0,
                    lastMessagePreview: hasTrustedDevice ? "Ready for OMEMO messages" : "Trust OMEMO device before sending",
                    lastActivityAt: Date.distantPast
                )
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func timeline(roomID: String, session: MatrixSession) async throws -> [MatrixTimelineItem] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        loadCachedTimelineItems(accountJID: accountJID, roomID: peerJID)
        do {
            let archive = try await archivedTimelineResult(peerJID: peerJID, accountJID: accountJID, connection: connection)
            if !archive.items.isEmpty {
                storeTimelineItems(archive.items, accountJID: accountJID, roomID: peerJID)
            }
            storeTimelineDiagnostics(
                XMPPTimelineDiagnostics(
                    mamQuerySucceeded: true,
                    mamRawCount: archive.rawCount,
                    mamFilteredCount: archive.filteredCount,
                    mamEncryptedCount: archive.encryptedCount,
                    mamDecodedCount: archive.items.count,
                    cachedCount: timelineItems(accountJID: accountJID, roomID: peerJID).count,
                    usedUnfilteredFallback: archive.usedUnfilteredFallback
                ),
                accountJID: accountJID,
                roomID: peerJID
            )
        } catch {
            // Keep the cached/live timeline visible when MAM is not available yet.
            storeTimelineDiagnostics(
                XMPPTimelineDiagnostics(
                    mamQuerySucceeded: false,
                    mamRawCount: 0,
                    mamFilteredCount: 0,
                    mamEncryptedCount: 0,
                    mamDecodedCount: 0,
                    cachedCount: timelineItems(accountJID: accountJID, roomID: peerJID).count,
                    usedUnfilteredFallback: false
                ),
                accountJID: accountJID,
                roomID: peerJID
            )
        }

        return timelineItems(accountJID: accountJID, roomID: peerJID)
    }

    func timelineDiagnostics(roomID: String, session: MatrixSession) async throws -> XMPPTimelineDiagnostics? {
        let peerJID = try Self.normalizedXMPPJID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        return timelineDiagnostics[accountJID.lowercased()]?[peerJID.lowercased()]
    }

    func sendText(_ text: String, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatrixClientError.emptyMessage
        }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(roomID)
        guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
            _ = try? await refreshPeerDeviceIdentities(userID: peerJID, session: session)
            guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
                throw MatrixClientError.omemoDeviceTrustRequired
            }
            return try await sendText(body, roomID: roomID, session: session)
        }

        let messageID = "trix-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .chat
        message.to = JID(peerJID)
        message.body = body

        let encryptedMessage = try await encodeOMEMOMessage(message, peerJID: peerJID, connection: connection)
        guard encryptedMessage.body == nil,
              let encrypted = encryptedMessage.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS),
              let header = encrypted.firstChild(name: "header"),
              !header.filterChildren(name: "key", xmlns: nil).isEmpty else {
            throw MatrixClientError.omemoEncryptionFailed
        }

        try await connection.omemoStack.module.write(stanza: encryptedMessage)

        let item = MatrixTimelineItem(
            id: messageID,
            roomID: peerJID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true,
            attachment: nil
        )
        storeTimelineItems([item], accountJID: session.userID, roomID: peerJID)
        return item
    }

    func sendAttachment(_ attachment: MatrixAttachmentUpload, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        guard !attachment.data.isEmpty else {
            throw MatrixClientError.emptyAttachment
        }

        _ = try await ensureConnection(for: session)
        _ = try Self.normalizedXMPPJID(roomID)
        throw MatrixClientError.e2eeUnavailable
    }

    func downloadAttachment(_ attachment: MatrixTimelineAttachment, session: MatrixSession) async throws -> MatrixAttachmentDownload {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.attachmentDownloadUnavailable
    }

    func members(roomID: String, session: MatrixSession) async throws -> [MatrixRoomMember] {
        let peerJID = try Self.normalizedXMPPJID(roomID)
        return [
            MatrixRoomMember(userID: session.userID, displayName: Self.displayName(from: session.userID), membership: .joined),
            MatrixRoomMember(userID: peerJID, displayName: Self.displayName(from: peerJID), membership: .joined),
        ]
    }

    func inviteUser(_ userID: String, roomID: String, session: MatrixSession) async throws {
        _ = try await ensureConnection(for: session)
        _ = try Self.normalizedXMPPJID(userID)
        _ = try Self.normalizedXMPPJID(roomID)
        throw MatrixClientError.e2eeUnavailable
    }

    func removeUser(_ userID: String, roomID: String, session: MatrixSession) async throws {
        _ = try await ensureConnection(for: session)
        _ = try Self.normalizedXMPPJID(userID)
        _ = try Self.normalizedXMPPJID(roomID)
        throw MatrixClientError.e2eeUnavailable
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(inviteeUserID)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.displayName(from: peerJID) : name
        try await ensureDirectRosterItem(peerJID: peerJID, displayName: displayName, connection: connection)

        return MatrixRoomSummary(
            id: peerJID,
            name: displayName,
            kind: .direct,
            isEncrypted: connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID),
            unreadCount: 0,
            lastMessagePreview: "Trust OMEMO device before sending",
            lastActivityAt: Date()
        )
    }

    func createEncryptedGroupRoom(
        name: String,
        inviteeUserIDs: [String],
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        _ = try await ensureConnection(for: session)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MatrixClientError.groupRoomNameRequired
        }
        guard inviteeUserIDs.count >= 2 else {
            throw MatrixClientError.groupInviteesRequired
        }
        throw MatrixClientError.e2eeUnavailable
    }

    func invitations(session: MatrixSession) async throws -> [MatrixRoomInvite] {
        _ = try await ensureConnection(for: session)
        return []
    }

    func acceptInvitation(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        _ = try await ensureConnection(for: session)
        _ = try Self.normalizedXMPPJID(roomID)
        throw MatrixClientError.inviteUnavailable
    }

    func declineInvitation(roomID: String, session: MatrixSession) async throws {
        _ = try await ensureConnection(for: session)
        _ = try Self.normalizedXMPPJID(roomID)
        throw MatrixClientError.inviteUnavailable
    }

    func joinRoom(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        let roomJID = try Self.normalizedXMPPJID(roomID)
        let connection = try await ensureConnection(for: session)
        try await ensureDirectRosterItem(peerJID: roomJID, displayName: Self.displayName(from: roomJID), connection: connection)
        return MatrixRoomSummary(
            id: roomJID,
            name: Self.displayName(from: roomJID),
            kind: .direct,
            isEncrypted: false,
            unreadCount: 0,
            lastMessagePreview: "OMEMO setup required before sending",
            lastActivityAt: Date()
        )
    }

    func joinInvitedRooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        _ = try await ensureConnection(for: session)
        return []
    }

    func deviceVerificationStatus(session: MatrixSession) async throws -> MatrixDeviceVerificationStatus {
        let connection = try await ensureConnection(for: session)
        let registrationID = connection.omemoStack.store.localRegistrationId()
        let localAddress = SignalAddress(name: session.userID, deviceId: Int32(bitPattern: registrationID))
        let fingerprint = connection.omemoStack.store.identityFingerprint(forAddress: localAddress)

        return MatrixDeviceVerificationStatus(
            userID: session.userID,
            deviceID: String(registrationID),
            state: fingerprint == nil ? .unknown : .verified,
            hasDevicesToVerifyAgainst: false,
            isLastDevice: true,
            recoveryState: .disabled,
            backupState: .unknown,
            backupExistsOnServer: nil,
            ed25519Fingerprint: fingerprint,
            curve25519IdentityKey: nil,
            updatedAt: Date()
        )
    }

    func deviceVerificationFlow(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        return .idle
    }

    func peerDeviceIdentities(userID: String, session: MatrixSession) async throws -> [MatrixPeerDeviceIdentity] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(userID)
        return Self.peerDeviceIdentities(from: connection.omemoStack.store.identities(forName: peerJID), userID: peerJID)
    }

    func refreshPeerDeviceIdentities(userID: String, session: MatrixSession) async throws -> [MatrixPeerDeviceIdentity] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(userID)
        let bareJID = BareJID(peerJID)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.omemoStack.module.addresses(for: [bareJID]) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure:
                    continuation.resume(throwing: MatrixClientError.e2eeUnavailable)
                }
            }
        }

        return Self.peerDeviceIdentities(from: connection.omemoStack.store.identities(forName: peerJID), userID: peerJID)
    }

    func trustPeerDevice(userID: String, deviceID: String, session: MatrixSession) async throws -> [MatrixPeerDeviceIdentity] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(userID)
        if !connection.omemoStack.store.trustIdentity(forName: peerJID, deviceID: deviceID) {
            _ = try await refreshPeerDeviceIdentities(userID: peerJID, session: session)
            guard connection.omemoStack.store.trustIdentity(forName: peerJID, deviceID: deviceID) else {
                throw MatrixClientError.omemoDeviceTrustRequired
            }
        }

        return Self.peerDeviceIdentities(from: connection.omemoStack.store.identities(forName: peerJID), userID: peerJID)
    }

    func requestDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func acceptDeviceVerificationRequest(
        _ request: MatrixDeviceVerificationRequest,
        session: MatrixSession
    ) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func startSasDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func approveDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func declineDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func cancelDeviceVerification(session: MatrixSession) async throws -> MatrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        return .idle
    }

    func setUpRecovery(session: MatrixSession) async throws -> String {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: MatrixSession) async throws -> MatrixDeviceVerificationStatus {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.e2eeUnavailable
    }

    func searchUsers(
        _ searchTerm: String,
        limit: Int,
        session: MatrixSession
    ) async throws -> MatrixUserSearchResult {
        let connection = try await refreshedRosterConnection(for: session)

        let rosterUsers = connection.rosterModule.rosterManager
            .items(for: connection.client)
            .map { item in
                MatrixUserProfile(
                    userID: item.jid.bareJid.stringValue,
                    displayName: item.name,
                    avatarURL: nil
                )
            }

        var users = rosterUsers + (try await searchDirectoryUsers(searchTerm, limit: limit, connection: connection))
        if let directJID = try? Self.normalizedXMPPJID(searchTerm),
           !users.contains(where: { $0.userID.lowercased() == directJID.lowercased() }) {
            users.append(MatrixUserProfile(userID: directJID, displayName: Self.displayName(from: directJID), avatarURL: nil))
        }

        let needle = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let uniqueUsers = Self.deduplicatedUsers(users)
        let filtered = needle.isEmpty
            ? uniqueUsers
            : uniqueUsers.filter { user in
                user.userID.lowercased().contains(needle)
                    || (user.displayName?.lowercased().contains(needle) == true)
            }

        return MatrixUserSearchResult(users: Array(filtered.prefix(max(limit, 0))), limited: filtered.count > limit)
    }

    func profile(userID: String, session: MatrixSession) async throws -> MatrixUserProfile {
        _ = try await ensureConnection(for: session)
        let jid = try Self.normalizedXMPPJID(userID)
        return MatrixUserProfile(userID: jid, displayName: Self.displayName(from: jid), avatarURL: nil)
    }

    func updateDisplayName(_ displayName: String, session: MatrixSession) async throws -> MatrixUserProfile {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.sdkAdapterUnavailable
    }

    func updateProfile(_ update: MatrixUserProfileUpdate, session: MatrixSession) async throws -> MatrixUserProfile {
        _ = try await ensureConnection(for: session)
        throw MatrixClientError.sdkAdapterUnavailable
    }

    private func ensureConnection(for session: MatrixSession) async throws -> Connection {
        let key = Self.sessionKey(session)
        if let connection = connections[key] {
            if connection.client.isConnected {
                return connection
            }

            connections.removeValue(forKey: key)
            try? await connection.client.disconnect(force: true)
        }

        return try await openConnection(for: session)
    }

    private func refreshedRosterConnection(for session: MatrixSession) async throws -> Connection {
        let connection = try await ensureConnection(for: session)
        do {
            try await connection.rosterModule.requestRoster()
            return connection
        } catch {
            guard Self.shouldReconnect(after: error) else {
                throw error
            }
        }

        let reconnected = try await reconnect(for: session)
        try await reconnected.rosterModule.requestRoster()
        return reconnected
    }

    private func reconnect(for session: MatrixSession) async throws -> Connection {
        let key = Self.sessionKey(session)
        if let existing = connections.removeValue(forKey: key) {
            try? await existing.client.disconnect(force: true)
        }
        return try await openConnection(for: session)
    }

    private func waitForOMEMOReady(connection: Connection) async {
        for _ in 0..<30 {
            if connection.omemoStack.module.isReady {
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func installTimelineSubscriptions(for connection: Connection) {
        connection.cancellables.removeAll()
        let service = self

        connection.messageCaptureModule.messagesPublisher
            .sink { [weak connection] message in
                guard let connection else {
                    return
                }

                let capturedMessage = CapturedMessage(message: message, carbonAction: nil)
                Task {
                    await service.recordLiveMessage(capturedMessage, connection: connection)
                }
            }
            .store(in: &connection.cancellables)

        connection.carbonsModule.carbonsPublisher
            .sink { [weak connection] carbon in
                guard let connection else {
                    return
                }

                let capturedMessage = CapturedMessage(message: carbon.message, carbonAction: carbon.action)
                Task {
                    await service.recordLiveMessage(capturedMessage, connection: connection)
                }
            }
            .store(in: &connection.cancellables)
    }

    private func openConnection(for session: MatrixSession) async throws -> Connection {
        let jid = try Self.normalizedXMPPJID(session.userID)
        guard !session.accessToken.isEmpty else {
            throw MatrixClientError.missingSession
        }

        let connection = try makeConnection(jid: jid, password: session.accessToken, resource: session.deviceID)
        do {
            try await connection.client.loginAndWait()
        } catch {
            throw MatrixClientError.xmppConnectionFailed
        }
        await waitForOMEMOReady(connection: connection)
        await replaceConnection(connection, for: session)
        try? await connection.carbonsModule.enable()
        try? await publishDirectoryProfileIfNeeded(session: session, connection: connection)
        return connection
    }

    private func replaceConnection(_ connection: Connection, for session: MatrixSession) async {
        let key = Self.sessionKey(session)
        if let existing = connections[key] {
            try? await existing.client.disconnect(force: true)
        }
        installTimelineSubscriptions(for: connection)
        connections[key] = connection
    }

    private func archivedTimelineResult(
        peerJID: String,
        accountJID: String,
        connection: Connection
    ) async throws -> ArchivedTimelineResult {
        let peerBareJID = BareJID(peerJID)
        connection.omemoStack.module.mamSyncStarted(for: peerBareJID)
        defer {
            connection.omemoStack.module.mamSyncFinished(for: peerBareJID)
        }

        let filteredEvents = try await archiveEvents(peerJID: peerJID, connection: connection)
        var events = filteredEvents
        var rawCount = filteredEvents.count
        var usedUnfilteredFallback = false

        if filteredEvents.isEmpty {
            let unfilteredEvents = try await archiveEvents(peerJID: nil, connection: connection)
            rawCount = unfilteredEvents.count
            events = unfilteredEvents.filter {
                Self.messageMatchesPeer($0.message, peerJID: peerJID, accountJID: accountJID)
            }
            usedUnfilteredFallback = !unfilteredEvents.isEmpty
        }

        var items: [MatrixTimelineItem] = []
        var encryptedCount = 0
        for archived in events {
            if archived.message.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS) != nil {
                encryptedCount += 1
            }
            if let item = timelineItem(
                from: archived.message,
                accountJID: accountJID,
                roomID: peerJID,
                timestamp: archived.timestamp,
                fallbackID: archived.messageId,
                connection: connection
            ) {
                items.append(item)
            }
        }

        return ArchivedTimelineResult(
            items: items,
            rawCount: rawCount,
            filteredCount: events.count,
            encryptedCount: encryptedCount,
            usedUnfilteredFallback: usedUnfilteredFallback
        )
    }

    private func archiveEvents(peerJID: String?, connection: Connection) async throws -> [MessageArchiveManagementModule.ArchivedMessageReceived] {
        let queryID = "trix-mam-\(UUID().uuidString)"
        let collector = MAMArchiveCollector()
        let cancellable = connection.mamModule.archivedMessagesPublisher.sink { event in
            guard event.query.id == queryID else {
                return
            }

            collector.append(event)
        }
        defer {
            cancellable.cancel()
        }

        let rsm = RSM.Query(lastItems: 50)
        do {
            try await queryArchive(version: .MAM2, peerJID: peerJID, queryID: queryID, rsm: rsm, connection: connection)
        } catch {
            try await queryArchive(version: .MAM1, peerJID: peerJID, queryID: queryID, rsm: rsm, connection: connection)
        }

        return collector.snapshot()
    }

    private func queryArchive(
        version: MessageArchiveManagementModule.Version,
        peerJID: String?,
        queryID: String,
        rsm: RSM.Query,
        connection: Connection
    ) async throws {
        let query = MAMQueryForm(version: version)
        if let peerJID {
            query.with = JID(peerJID)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.mamModule.queryItems(
                version: version,
                query: query,
                queryId: queryID,
                rsm: rsm
            ) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func recordLiveMessage(
        _ capturedMessage: CapturedMessage,
        connection: Connection
    ) async {
        let message = capturedMessage.message
        let accountJID = connection.client.connectionConfiguration.userJid.stringValue
        guard let roomID = Self.roomID(for: message, accountJID: accountJID, carbonAction: capturedMessage.carbonAction),
              let item = timelineItem(
                from: message,
                accountJID: accountJID,
                roomID: roomID,
                timestamp: Self.messageTimestamp(message, fallback: Date()),
                fallbackID: nil,
                connection: connection
              ) else {
            return
        }

        storeTimelineItems([item], accountJID: accountJID, roomID: roomID)
    }

    private func timelineItem(
        from message: Message,
        accountJID: String,
        roomID: String,
        timestamp: Date,
        fallbackID: String?,
        connection: Connection
    ) -> MatrixTimelineItem? {
        guard message.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS) != nil else {
            return nil
        }

        let decoded: Message
        switch connection.omemoStack.module.decode(message: message, serverMsgId: fallbackID) {
        case .successMessage(let decryptedMessage, _):
            decoded = decryptedMessage
        case .successTransportKey, .failure:
            return nil
        }

        guard let body = decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            return nil
        }

        let senderJID = decoded.from?.bareJid.stringValue ?? roomID
        let normalizedAccountJID = accountJID.lowercased()
        let isLocalEcho = senderJID.lowercased() == normalizedAccountJID
        return MatrixTimelineItem(
            id: decoded.id ?? fallbackID ?? "xmpp-\(UUID().uuidString)",
            roomID: roomID,
            sender: isLocalEcho ? accountJID : senderJID,
            timestamp: timestamp,
            body: body,
            isLocalEcho: isLocalEcho,
            attachment: nil
        )
    }

    private func storeTimelineItems(_ items: [MatrixTimelineItem], accountJID: String, roomID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        let existingItems = timelineHistory[accountKey]?[roomKey] ?? []
        var accountHistory = timelineHistory[accountKey] ?? [:]
        let mergedItems = Array(Self.mergedTimelineItems(existingItems, items).suffix(Self.maxCachedTimelineItems))
        accountHistory[roomKey] = mergedItems
        timelineHistory[accountKey] = accountHistory
        try? timelineCacheStore.save(mergedItems, accountJID: accountJID, roomID: roomID)
    }

    private func timelineItems(accountJID: String, roomID: String) -> [MatrixTimelineItem] {
        timelineHistory[accountJID.lowercased()]?[roomID.lowercased()] ?? []
    }

    private func loadCachedTimelineItems(accountJID: String, roomID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        guard timelineHistory[accountKey]?[roomKey] == nil,
              let cachedItems = try? timelineCacheStore.load(accountJID: accountJID, roomID: roomID),
              !cachedItems.isEmpty else {
            return
        }

        var accountHistory = timelineHistory[accountKey] ?? [:]
        accountHistory[roomKey] = cachedItems
        timelineHistory[accountKey] = accountHistory
    }

    private func storeTimelineDiagnostics(_ diagnostics: XMPPTimelineDiagnostics, accountJID: String, roomID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        var accountDiagnostics = timelineDiagnostics[accountKey] ?? [:]
        accountDiagnostics[roomKey] = diagnostics
        timelineDiagnostics[accountKey] = accountDiagnostics
    }

    private func encodeOMEMOMessage(_ message: Message, peerJID: String, connection: Connection) async throws -> Message {
        await ensureOwnOMEMOSession(connection: connection)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Message, Error>) in
            connection.omemoStack.module.encode(message: message, for: [BareJID(peerJID)]) { result in
                switch result {
                case .successMessage(let encryptedMessage, _):
                    continuation.resume(returning: encryptedMessage)
                case .failure:
                    continuation.resume(throwing: MatrixClientError.omemoEncryptionFailed)
                }
            }
        }
    }

    private func ensureOwnOMEMOSession(connection: Connection) async {
        let registrationID = connection.omemoStack.store.localRegistrationId()
        guard registrationID != 0 else {
            return
        }

        let address = SignalAddress(
            name: connection.client.connectionConfiguration.userJid.stringValue,
            deviceId: Int32(bitPattern: registrationID)
        )
        guard !connection.omemoStack.store.containsSessionRecord(forAddress: address) else {
            return
        }

        await withCheckedContinuation { continuation in
            let oneShot = OneShotVoidContinuation(continuation)

            connection.omemoStack.module.buildSession(forAddress: address) {
                oneShot.resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                oneShot.resume()
            }
        }
    }

    private func ensureDirectRosterItem(peerJID: String, displayName: String, connection: Connection) async throws {
        guard peerJID.caseInsensitiveCompare(connection.client.connectionConfiguration.userJid.stringValue) != .orderedSame else {
            throw MatrixClientError.invalidMatrixUserID
        }

        let jid = JID(peerJID)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? Self.displayName(from: peerJID) : trimmedName
        _ = try await connection.rosterModule.addItem(jid: jid, name: finalName, groups: ["Trix"])
        try await connection.rosterModule.requestRoster()
    }

    private func publishDirectoryProfileIfNeeded(session: MatrixSession, connection: Connection) async throws {
        let displayName = Self.displayName(from: session.userID)
        let vcard = VCard()
        vcard.fn = displayName
        vcard.givenName = displayName
        vcard.nicknames = [displayName]
        vcard.impps = [VCard.IMPP(uri: "xmpp:\(session.userID)")]
        _ = try await connection.vCardModule.publish(vcard: vcard, to: nil)
    }

    private func searchDirectoryUsers(
        _ searchTerm: String,
        limit: Int,
        connection: Connection
    ) async throws -> [MatrixUserProfile] {
        let needle = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else {
            return []
        }

        if let allUsersResponse = try? await directorySearchResponse(fields: [:], connection: connection) {
            let users = Self.directoryUsers(from: allUsersResponse)
            if !users.isEmpty {
                return users
            }
        }

        var users: [MatrixUserProfile] = []
        for field in ["user", "nick", "fn", "first", "last", "email"] {
            let response = try? await directorySearchResponse(fields: [field: needle], connection: connection)
            if let response {
                users.append(contentsOf: Self.directoryUsers(from: response))
            }
        }

        return Self.deduplicatedUsers(users)
    }

    private func directorySearchResponse(fields: [String: String], connection: Connection) async throws -> Iq {
        let iq = Iq()
        iq.type = .set
        iq.to = JID(XMPPClientConfiguration.directoryServerName)

        let query = Element(name: "query", xmlns: "jabber:iq:search")
        let dataForm = Element(name: "x", xmlns: "jabber:x:data")
        dataForm.setAttribute("type", value: "submit")

        for field in fields.sorted(by: { $0.key < $1.key }) {
            let fieldElement = Element(name: "field")
            fieldElement.setAttribute("var", value: field.key)
            fieldElement.addChild(Element(name: "value", cdata: field.value))
            dataForm.addChild(fieldElement)
        }

        query.addChild(dataForm)
        iq.addChild(query)

        return try await connection.rosterModule.write(iq: iq, timeout: 10)
    }

    private func makeConnection(jid: String, password: String, resource: String) throws -> Connection {
        let omemoStack = try TrixOMEMOStore.makeStack(account: jid)
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(jid)
        client.connectionConfiguration.credentials = .password(password: password)
        client.connectionConfiguration.resource = resource
        client.connectionConfiguration.disableTLS = false
        client.connectionConfiguration.disableCompression = true
        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnector.Options.self) { options in
            options.sslCertificateValidation = .customValidator { trust in
                Self.validateServerTrust(trust, domain: jid)
            }
        }

        _ = client.modulesManager.register(StreamFeaturesModule())
        _ = client.modulesManager.register(AuthModule())
        _ = client.modulesManager.register(SaslModule())
        _ = client.modulesManager.register(ResourceBinderModule())
        _ = client.modulesManager.register(SessionEstablishmentModule())
        _ = client.modulesManager.register(DiscoveryModule())
        _ = client.modulesManager.register(PingModule())
        _ = client.modulesManager.register(PresenceModule())
        let messageCaptureModule = TrixMessageCaptureModule()
        _ = client.modulesManager.register(messageCaptureModule)
        let messageModule = MessageModule(chatManager: DefaultChatManager(store: DefaultChatStore()))
        _ = client.modulesManager.register(
            messageModule
        )
        let carbonsModule = MessageCarbonsModule()
        _ = client.modulesManager.register(carbonsModule)
        _ = client.modulesManager.register(StreamManagementModule())
        _ = client.modulesManager.register(ClientStateIndicationModule())
        let mamModule = MessageArchiveManagementModule()
        _ = client.modulesManager.register(mamModule)
        _ = client.modulesManager.register(HttpFileUploadModule())
        _ = client.modulesManager.register(PubSubModule())
        let vCardModule = VCardTempModule()
        _ = client.modulesManager.register(vCardModule)
        _ = client.modulesManager.register(omemoStack.module)

        let rosterModule = RosterModule(rosterManager: RosterManagerBase(store: TrixMartinRosterStore()))
        _ = client.modulesManager.register(rosterModule)

        return Connection(
            client: client,
            rosterModule: rosterModule,
            vCardModule: vCardModule,
            messageCaptureModule: messageCaptureModule,
            mamModule: mamModule,
            carbonsModule: carbonsModule,
            omemoStack: omemoStack
        )
    }

    private static func normalizedXMPPJID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw MatrixClientError.invalidMatrixUserID
        }

        if trimmed.hasPrefix("@"), let separator = trimmed.firstIndex(of: ":") {
            let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
            let server = String(trimmed[trimmed.index(after: separator)...])
            guard !localpart.isEmpty, server == XMPPClientConfiguration.serverName else {
                throw MatrixClientError.invalidMatrixUserID
            }
            return "\(localpart)@\(server)"
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localpart = parts.first,
              let domain = parts.last,
              !localpart.isEmpty,
              domain == XMPPClientConfiguration.serverName,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw MatrixClientError.invalidMatrixUserID
        }

        return trimmed
    }

    private static func validateServerTrust(_ trust: SecTrust, domain jid: String) -> Bool {
        let serverName = BareJID(jid).domain
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        SecTrustSetPolicies(trust, policy)

        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }

    private static func shouldReconnect(after error: Error) -> Bool {
        guard let xmppError = error as? XMPPError else {
            return false
        }

        return xmppError == .remote_server_timeout || xmppError == .undefined_condition
    }

    private static func roomID(
        for message: Message,
        accountJID: String,
        carbonAction: MessageCarbonsModule.Action?
    ) -> String? {
        let accountKey = accountJID.lowercased()

        switch carbonAction {
        case .sent:
            return message.to?.bareJid.stringValue
        case .received:
            return message.from?.bareJid.stringValue
        case nil:
            if let from = message.from?.bareJid.stringValue,
               from.lowercased() != accountKey {
                return from
            }

            if let to = message.to?.bareJid.stringValue,
               to.lowercased() != accountKey {
                return to
            }

            return nil
        }
    }

    private static func messageMatchesPeer(_ message: Message, peerJID: String, accountJID: String) -> Bool {
        let peerKey = peerJID.lowercased()
        let accountKey = accountJID.lowercased()
        let from = message.from?.bareJid.stringValue.lowercased()
        let to = message.to?.bareJid.stringValue.lowercased()

        if from == peerKey {
            return to == nil || to == accountKey
        }

        if to == peerKey {
            return from == nil || from == accountKey
        }

        return false
    }

    private static func messageTimestamp(_ message: Message, fallback: Date) -> Date {
        guard let delay = message.firstChild(name: "delay", xmlns: "urn:xmpp:delay"),
              let stamp = Delay(element: delay).stamp else {
            return fallback
        }

        return stamp
    }

    private static func mergedTimelineItems(
        _ lhs: [MatrixTimelineItem],
        _ rhs: [MatrixTimelineItem]
    ) -> [MatrixTimelineItem] {
        var byID: [String: MatrixTimelineItem] = [:]
        for item in lhs {
            byID[item.id] = item
        }
        for item in rhs {
            byID[item.id] = item
        }

        return byID.values.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }
    }

    private static func directoryUsers(from response: Iq) -> [MatrixUserProfile] {
        guard response.type == .result,
              let query = response.firstChild(name: "query", xmlns: "jabber:iq:search") else {
            return []
        }

        let legacyUsers = query.getChildren(name: "item").compactMap { item -> MatrixUserProfile? in
            guard let jid = normalizedDirectoryJID(item.getAttribute("jid")) else {
                return nil
            }

            let displayName = firstNonEmpty(
                item.findChild(name: "nick")?.value,
                item.findChild(name: "fn")?.value,
                item.findChild(name: "first")?.value,
                item.findChild(name: "last")?.value
            )
            return MatrixUserProfile(userID: jid, displayName: displayName ?? Self.displayName(from: jid), avatarURL: nil)
        }

        let formUsers = query
            .getChildren(name: "x", xmlns: "jabber:x:data")
            .flatMap { form in
                form.getChildren(name: "item").compactMap { item -> MatrixUserProfile? in
                    var fields: [String: String] = [:]
                    for field in item.getChildren(name: "field") {
                        guard let name = field.getAttribute("var"),
                              let value = field.findChild(name: "value")?.value,
                              !value.isEmpty else {
                            continue
                        }
                        fields[name.lowercased()] = value
                    }

                    guard let jid = normalizedDirectoryJID(fields["jid"] ?? fields["user"]) else {
                        return nil
                    }
                    let displayName = firstNonEmpty(fields["nick"], fields["fn"], fields["first"], fields["last"])
                    return MatrixUserProfile(userID: jid, displayName: displayName ?? Self.displayName(from: jid), avatarURL: nil)
                }
            }

        return deduplicatedUsers(legacyUsers + formUsers)
    }

    private static func deduplicatedUsers(_ users: [MatrixUserProfile]) -> [MatrixUserProfile] {
        var seen = Set<String>()
        var result: [MatrixUserProfile] = []
        for user in users {
            let key = user.userID.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(user)
        }
        return result
    }

    private static func normalizedDirectoryJID(_ jid: String?) -> String? {
        guard let jid = jid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let normalized = try? normalizedXMPPJID(jid),
              normalized.split(separator: "@").last.map(String.init) == XMPPClientConfiguration.serverName else {
            return nil
        }
        return normalized
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func displayName(from jid: String) -> String {
        let trimmed = jid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            return trimmed
                .dropFirst()
                .split(separator: ":")
                .first
                .map { String($0).capitalized } ?? trimmed
        }

        return trimmed
            .split(separator: "@")
            .first
            .map { String($0).capitalized } ?? trimmed
    }

    private static func resourceName() -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(XMPPClientConfiguration.defaultResourcePrefix)-\(suffix)"
    }

    private static func sessionKey(_ session: MatrixSession) -> String {
        session.userID.lowercased()
    }

    private static func peerDeviceIdentities(from identities: [Identity], userID: String) -> [MatrixPeerDeviceIdentity] {
        identities
            .filter { !$0.own }
            .map { identity in
                MatrixPeerDeviceIdentity(
                    userID: userID,
                    deviceID: String(UInt32(bitPattern: identity.address.deviceId)),
                    fingerprint: identity.fingerprint,
                    trustState: peerTrustState(from: identity.status.trust),
                    isActive: identity.status.isActive,
                    isLocalDevice: identity.own
                )
            }
            .sorted { lhs, rhs in
                if lhs.canSendEncrypted != rhs.canSendEncrypted {
                    return lhs.canSendEncrypted && !rhs.canSendEncrypted
                }

                return lhs.deviceID < rhs.deviceID
            }
    }

    private static func peerTrustState(from trust: Trust) -> MatrixPeerDeviceTrustState {
        switch trust {
        case .undecided:
            return .undecided
        case .trusted:
            return .trusted
        case .verified:
            return .verified
        case .compromised:
            return .compromised
        }
    }
}
