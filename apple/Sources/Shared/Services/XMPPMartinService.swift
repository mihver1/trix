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
    let mamLocalKeyCount: Int
    let mamAccountSenderCount: Int
    let mamAccountSenderMissingLocalKeyCount: Int
    let mamPeerSenderCount: Int
    let localCacheLoadedCount: Int
    let cachedCount: Int
    let usedUnfilteredFallback: Bool
}

actor XMPPMartinService: TrixService {
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

    private struct ArchivedMessageSnapshot: @unchecked Sendable {
        let messageID: String
        let timestamp: Date
        let message: Message
    }

    private final class MAMArchiveCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ArchivedMessageSnapshot] = []

        func append(_ event: MessageArchiveManagementModule.ArchivedMessageReceived) {
            guard let message = XMPPMartinService.detachedMessage(event.message) else {
                return
            }

            append(
                ArchivedMessageSnapshot(
                    messageID: event.messageId,
                    timestamp: event.timestamp,
                    message: message
                )
            )
        }

        private func append(_ event: ArchivedMessageSnapshot) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [ArchivedMessageSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    private struct CapturedMessage: @unchecked Sendable {
        let message: Message
        let accountJID: String
        let carbonAction: MessageCarbonsModule.Action?
    }

    private struct CapturedDeliveryReceipt: Sendable {
        let messageID: String
        let roomID: String?
    }

    private struct CapturedReactionUpdate: Sendable {
        let messageID: String
        let roomID: String
        let senderJID: String
        let emojis: [String]
        let timestamp: Date
    }

    private struct TypingRecord: Sendable {
        let userID: String
        let state: TrixTypingState
        let updatedAt: Date
    }

    private struct EncryptedAttachmentDescriptor: Codable, Equatable, Sendable {
        let type: String
        let version: Int
        let downloadURL: String
        let fragment: String
        let filename: String
        let mimeType: String?
        let originalSizeBytes: Int
        let encryptedSizeBytes: Int
        let imageDimensions: TrixAttachmentImageDimensions?
        let imageBlurhash: String?
        let stickerMetadata: TrixStickerAttachmentMetadata?
    }

    private struct EncryptedCallDescriptorEnvelope: Codable, Equatable, Sendable {
        let type: String
        let version: Int
        let payload: Data
    }

    private struct DecodedTimelineContent {
        let body: String
        let attachment: TrixTimelineAttachment?
    }

    private struct KnownGroupRoom: Sendable {
        let roomID: String
        var name: String
        var memberUserIDs: Set<String>
        var lastActivityAt: Date

        init(roomID: String, name: String, memberUserIDs: Set<String>, lastActivityAt: Date) {
            self.roomID = roomID
            self.name = name
            self.memberUserIDs = Set(memberUserIDs.map { $0.lowercased() })
            self.lastActivityAt = lastActivityAt
        }

        init(cached: TrixCachedGroupRoom) {
            self.init(
                roomID: cached.roomID,
                name: cached.name,
                memberUserIDs: cached.memberUserIDs,
                lastActivityAt: cached.lastActivityAt
            )
        }

        var cached: TrixCachedGroupRoom {
            TrixCachedGroupRoom(
                roomID: roomID,
                name: name,
                memberUserIDs: memberUserIDs,
                lastActivityAt: lastActivityAt
            )
        }
    }

    private enum MUCInvitationTransport: String, Codable, Sendable {
        case mediated
        case direct
        case unknown
    }

    private struct CapturedMUCInvitation: Codable, Sendable {
        let roomID: String
        let roomName: String
        let inviterUserID: String?
        let password: String?
        let reason: String?
        let receivedAt: Date
        let transport: MUCInvitationTransport
    }

    private struct DismissedMUCInvitation: Codable, Sendable {
        let roomID: String
        let dismissedAt: Date
    }

    private struct StoredMUCInvitationState: Codable, Sendable {
        let version: Int
        let pending: [CapturedMUCInvitation]
        let dismissed: [DismissedMUCInvitation]

        static let empty = StoredMUCInvitationState(version: 1, pending: [], dismissed: [])
    }

    private struct CapturedMUCMessage: @unchecked Sendable {
        let roomID: String
        let senderJID: String?
        let knownMemberUserIDs: Set<String>
        let message: Message
    }

    private struct GroupAffiliationRecord: Sendable {
        let userID: String
        let nickname: String?
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
        let items: [TrixTimelineItem]
        let rawCount: Int
        let filteredCount: Int
        let encryptedCount: Int
        let localKeyCount: Int
        let accountSenderCount: Int
        let accountSenderMissingLocalKeyCount: Int
        let peerSenderCount: Int
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

    private final class TrixMucRoomStore: RoomStore, @unchecked Sendable {
        typealias Room = RoomBase

        private let dispatcher = QueueDispatcher(label: "TrixMucRoomStore")
        private var rooms: [BareJID: RoomBase] = [:]

        func rooms(for context: Context) -> [RoomBase] {
            dispatcher.sync {
                Array(rooms.values)
            }
        }

        func room(for context: Context, with jid: BareJID) -> RoomBase? {
            dispatcher.sync {
                rooms[jid]
            }
        }

        func createRoom(
            for context: Context,
            with jid: BareJID,
            nickname: String,
            password: String?
        ) -> ConversationCreateResult<RoomBase> {
            dispatcher.sync {
                if let room = rooms[jid] {
                    return .found(room)
                }

                let room = RoomBase(
                    context: context,
                    jid: jid,
                    nickname: nickname,
                    password: password,
                    dispatcher: dispatcher
                )
                rooms[jid] = room
                return .created(room)
            }
        }

        func close(room: RoomBase) -> Bool {
            dispatcher.sync {
                rooms.removeValue(forKey: room.jid) != nil
            }
        }

        func initialize(context: Context) {}

        func deinitialize(context: Context) {}
    }

    private final class TrixMUCInvitationCacheStore: @unchecked Sendable {
        private let service: String
        private let encoder = JSONEncoder()
        private let decoder = JSONDecoder()

        init(service: String = "com.softgrid.trix.xmpp.muc-invitations") {
            self.service = service
            encoder.dateEncodingStrategy = .iso8601
            decoder.dateDecodingStrategy = .iso8601
        }

        func load(accountJID: String) throws -> StoredMUCInvitationState {
            var query = baseQuery(accountJID: accountJID)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return .empty
            }

            guard status == errSecSuccess else {
                throw TrixClientError.keychainFailure(status.description)
            }
            guard let data = result as? Data else {
                throw TrixClientError.keychainFailure("stored MUC invitations have unexpected format")
            }

            return try decoder.decode(StoredMUCInvitationState.self, from: data)
        }

        func save(_ state: StoredMUCInvitationState, accountJID: String) throws {
            let data = try encoder.encode(state)
            let query = baseQuery(accountJID: accountJID)
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return
            }

            guard updateStatus == errSecItemNotFound else {
                throw TrixClientError.keychainFailure(updateStatus.description)
            }

            var item = query
            item[kSecValueData as String] = data
#if os(iOS)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif

            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TrixClientError.keychainFailure(addStatus.description)
            }
        }

        private func baseQuery(accountJID: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "muc-invitations:\(accountJID.lowercased())",
            ]
        }
    }

    private final class Connection: @unchecked Sendable {
        let client: XMPPClient
        let rosterModule: RosterModule
        let vCardModule: VCardTempModule
        let messageCaptureModule: TrixMessageCaptureModule
        let mamModule: MessageArchiveManagementModule
        let carbonsModule: MessageCarbonsModule
        let deliveryReceiptsModule: MessageDeliveryReceiptsModule
        let chatStateModule: ChatStateNotificationsModule
        let csiModule: ClientStateIndicationModule
        let mucModule: MucModule
        let bookmarksModule: PEPBookmarksModule
        let pubSubModule: PubSubModule
        let pushModule: TigasePushNotificationsModule
        let omemoStack: TrixOMEMOStack
        let createdAt: Date
        var applicationIsActive: Bool?
        var cancellables: Set<AnyCancellable> = []

        init(
            client: XMPPClient,
            rosterModule: RosterModule,
            vCardModule: VCardTempModule,
            messageCaptureModule: TrixMessageCaptureModule,
            mamModule: MessageArchiveManagementModule,
            carbonsModule: MessageCarbonsModule,
            deliveryReceiptsModule: MessageDeliveryReceiptsModule,
            chatStateModule: ChatStateNotificationsModule,
            csiModule: ClientStateIndicationModule,
            mucModule: MucModule,
            bookmarksModule: PEPBookmarksModule,
            pubSubModule: PubSubModule,
            pushModule: TigasePushNotificationsModule,
            omemoStack: TrixOMEMOStack,
            createdAt: Date = Date()
        ) {
            self.client = client
            self.rosterModule = rosterModule
            self.vCardModule = vCardModule
            self.messageCaptureModule = messageCaptureModule
            self.mamModule = mamModule
            self.carbonsModule = carbonsModule
            self.deliveryReceiptsModule = deliveryReceiptsModule
            self.chatStateModule = chatStateModule
            self.csiModule = csiModule
            self.mucModule = mucModule
            self.bookmarksModule = bookmarksModule
            self.pubSubModule = pubSubModule
            self.pushModule = pushModule
            self.omemoStack = omemoStack
            self.createdAt = createdAt
        }
    }

    private final class XMPPLoginWaitState: @unchecked Sendable {
        private let client: XMPPClient
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancellable: AnyCancellable?

        init(continuation: CheckedContinuation<Void, Error>, client: XMPPClient) {
            self.continuation = continuation
            self.client = client
        }

        func retain(_ cancellable: AnyCancellable) {
            lock.lock()
            if continuation == nil {
                lock.unlock()
                cancellable.cancel()
                return
            }

            self.cancellable = cancellable
            lock.unlock()
        }

        func resumeReturning() {
            finish(.success(()), disconnect: false)
        }

        func resumeThrowing(_ error: Error, disconnect: Bool) {
            finish(.failure(error), disconnect: disconnect)
        }

        private func finish(_ result: Result<Void, Error>, disconnect: Bool) {
            let activeContinuation: CheckedContinuation<Void, Error>
            let activeCancellable: AnyCancellable?

            lock.lock()
            guard let storedContinuation = continuation else {
                lock.unlock()
                return
            }

            activeContinuation = storedContinuation
            activeCancellable = cancellable
            continuation = nil
            cancellable = nil
            lock.unlock()

            activeCancellable?.cancel()
            if disconnect {
                let client = client
                Task {
                    try? await client.disconnect(force: true)
                }
            }

            switch result {
            case .success:
                activeContinuation.resume()
            case .failure(let error):
                activeContinuation.resume(throwing: error)
            }
        }
    }

    private final class XMPPMUCJoinWaitState: @unchecked Sendable {
        private let mucModule: MucModule
        private let room: RoomProtocol
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RoomJoinResult, Error>?

        init(
            continuation: CheckedContinuation<RoomJoinResult, Error>,
            mucModule: MucModule,
            room: RoomProtocol
        ) {
            self.continuation = continuation
            self.mucModule = mucModule
            self.room = room
        }

        func resume(with result: Result<RoomJoinResult, XMPPError>) {
            switch result {
            case .success(let joinResult):
                finish(.success(joinResult), leaveRoom: false)
            case .failure(let error):
                finish(.failure(error), leaveRoom: false)
            }
        }

        func resumeThrowing(_ error: Error, leaveRoom: Bool) {
            finish(.failure(error), leaveRoom: leaveRoom)
        }

        private func finish(_ result: Result<RoomJoinResult, Error>, leaveRoom: Bool) {
            let activeContinuation: CheckedContinuation<RoomJoinResult, Error>

            lock.lock()
            guard let storedContinuation = continuation else {
                lock.unlock()
                return
            }

            activeContinuation = storedContinuation
            continuation = nil
            lock.unlock()

            if leaveRoom {
                mucModule.leave(room: room)
            }

            switch result {
            case .success(let joinResult):
                activeContinuation.resume(returning: joinResult)
            case .failure(let error):
                activeContinuation.resume(throwing: error)
            }
        }
    }

    private var connections: [String: Connection] = [:]
    private var timelineHistory: [String: [String: [TrixTimelineItem]]] = [:]
    private var timelineDiagnostics: [String: [String: XMPPTimelineDiagnostics]] = [:]
    private var typingRecords: [String: [String: [String: TypingRecord]]] = [:]
    private var knownGroupRooms: [String: [String: KnownGroupRoom]] = [:]
    private var pendingGroupInvitations: [String: [String: CapturedMUCInvitation]] = [:]
    private var dismissedGroupInvitations: [String: [String: Date]] = [:]
    private var invitationArchiveSyncConnectionDates: [String: Date] = [:]
    private var callDescriptorHistory: [String: [String: [TrixReceivedCallDescriptor]]] = [:]
    private let timelineCacheStore = TrixTimelineCacheStore()
    private let roomSummaryCacheStore = TrixRoomSummaryCacheStore()
    private let groupRoomCacheStore = TrixGroupRoomCacheStore()
    private let mucInvitationCacheStore = TrixMUCInvitationCacheStore()
    private let omemoPersistence: TrixOMEMOPersistence
    private static let maxCachedTimelineItems = 200
    private static let maxCachedCallDescriptors = 100
    private static let typingRecordLifetime: TimeInterval = 6
    private static let xmppConnectionTimeout: TimeInterval = 15
    private static let mucJoinTimeout: TimeInterval = 15
    private static let encryptedAttachmentDescriptorType = "com.softgrid.trix.xmpp.encrypted-attachment"
    private static let messageReactionsXMLNS = "urn:xmpp:reactions:0"
    private static let notificationProfilesNode = "urn:softgrid:trix:notification-profiles:1"
    private static let notificationProfilesItemID = "profiles"

    init(omemoPersistence: TrixOMEMOPersistence = .keychain) {
        self.omemoPersistence = omemoPersistence
    }

    func login(userID: String, password: String, serverURL: URL) async throws -> TrixSession {
        let jid = try Self.normalizedXMPPJID(userID)
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            throw TrixClientError.invalidCredentials
        }

        let resource = Self.resourceName()
        let connection = try makeConnection(jid: jid, password: password, resource: resource)

        do {
            try await loginAndWait(client: connection.client)
        } catch {
            throw TrixClientError.xmppConnectionFailed
        }
        await waitForOMEMOReady(connection: connection)

        let boundResource = connection.client.boundJid?.resource ?? resource
        let session = TrixSession(
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

    func restore(session: TrixSession) async throws -> TrixAccount {
        let connection = try await ensureConnection(for: session)
        return TrixAccount(
            userID: session.userID,
            displayName: Self.displayName(from: session.userID),
            deviceID: connection.client.boundJid?.resource ?? session.deviceID
        )
    }

    func logout(session: TrixSession) async throws {
        guard let connection = connections.removeValue(forKey: Self.sessionKey(session)) else {
            return
        }

        try? await connection.client.disconnect(force: true)
    }

    func registerAPNsToken(_ token: TrixAPNsDeviceToken, session: TrixSession) async throws -> TrixPushRegistration {
        let connection = try await ensureConnection(for: session)
        let gatewayJID = try await pushGatewayJID(connection: connection)
        let provider = token.environment.xmppPushProvider

        do {
            let registration = try await connection.pushModule.registerDevice(
                serviceJid: gatewayJID,
                provider: provider,
                deviceId: token.hexString
            )
            _ = try await connection.pushModule.enable(
                serviceJid: gatewayJID,
                node: registration.node
            )

            return TrixPushRegistration(
                environment: token.environment,
                provider: provider,
                gatewayJID: gatewayJID.stringValue,
                node: registration.node,
                registeredAt: Date()
            )
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.apnsRegistrationFailed
        }
    }

    func unregisterAPNsToken(
        _ token: TrixAPNsDeviceToken,
        registration: TrixPushRegistration?,
        session: TrixSession
    ) async throws {
        let connection = try await ensureConnection(for: session)
        let provider = token.environment.xmppPushProvider

        if let registration {
            let gatewayJID = JID(registration.gatewayJID)
            _ = try? await connection.pushModule.disable(serviceJid: gatewayJID, node: registration.node)
            try await connection.pushModule.unregisterDevice(
                serviceJid: gatewayJID,
                provider: provider,
                deviceId: token.hexString
            )
            return
        }

        let gatewayJID = try await pushGatewayJID(connection: connection)
        do {
            try await connection.pushModule.unregisterDevice(
                serviceJid: gatewayJID,
                provider: provider,
                deviceId: token.hexString
            )
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.apnsRegistrationFailed
        }
    }

    func registerVoIPToken(_ token: TrixVoIPDeviceToken, session: TrixSession) async throws -> TrixVoIPPushRegistration {
        let connection = try await ensureConnection(for: session)
        let gatewayJID = try await pushGatewayJID(connection: connection)
        let provider = token.environment.xmppVoIPPushProvider

        do {
            let registration = try await connection.pushModule.registerDevice(
                serviceJid: gatewayJID,
                provider: provider,
                deviceId: token.hexString
            )

            return TrixVoIPPushRegistration(
                environment: token.environment,
                provider: provider,
                gatewayJID: gatewayJID.stringValue,
                node: registration.node,
                registeredAt: Date()
            )
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.apnsRegistrationFailed
        }
    }

    func unregisterVoIPToken(
        _ token: TrixVoIPDeviceToken,
        registration: TrixVoIPPushRegistration?,
        session: TrixSession
    ) async throws {
        let connection = try await ensureConnection(for: session)
        let provider = token.environment.xmppVoIPPushProvider
        let gatewayJID: JID
        if let registration {
            gatewayJID = JID(registration.gatewayJID)
        } else {
            gatewayJID = try await pushGatewayJID(connection: connection)
        }

        do {
            try await connection.pushModule.unregisterDevice(
                serviceJid: gatewayJID,
                provider: provider,
                deviceId: token.hexString
            )
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.apnsRegistrationFailed
        }
    }

    func roomNotificationProfiles(session: TrixSession) async throws -> TrixRoomNotificationProfileSnapshot? {
        let connection = try await ensureConnection(for: session)
        let accountJID = try Self.normalizedXMPPJID(session.userID)

        do {
            let items = try await connection.pubSubModule.retrieveItems(
                from: BareJID(accountJID),
                for: Self.notificationProfilesNode,
                limit: .items(withIds: [Self.notificationProfilesItemID])
            )
            guard let payload = items.items.first?.payload else {
                return nil
            }
            return Self.notificationProfileSnapshot(from: payload)
        } catch let error as PubSubError where error.error == .item_not_found {
            return nil
        }
    }

    func updateRoomNotificationProfiles(
        _ snapshot: TrixRoomNotificationProfileSnapshot,
        session: TrixSession
    ) async throws {
        let connection = try await ensureConnection(for: session)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let payload = Self.notificationProfileElement(from: snapshot)

        do {
            _ = try await connection.pubSubModule.publishItem(
                at: nil,
                to: Self.notificationProfilesNode,
                itemId: Self.notificationProfilesItemID,
                payload: payload
            )
        } catch let error as PubSubError where error.error == .item_not_found {
            try await createNotificationProfilesNode(connection: connection, accountJID: accountJID)
            _ = try await connection.pubSubModule.publishItem(
                at: nil,
                to: Self.notificationProfilesNode,
                itemId: Self.notificationProfilesItemID,
                payload: payload
            )
        }
    }

    func setApplicationActive(_ isActive: Bool, session: TrixSession) async {
        let key = Self.sessionKey(session)
        guard let connection = connections[key],
              connection.client.isConnected else {
            return
        }

        await sendClientState(isActive: isActive, connection: connection)
    }

    func rooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        let connection = try await refreshedRosterConnection(for: session)
        let accountJID = try Self.normalizedXMPPJID(session.userID)

        let rosterItems = connection.rosterModule.rosterManager
            .items(for: connection.client)
            .filter { item in
                item.jid.bareJid.domain == XMPPClientConfiguration.serverName
            }

        var summaries: [TrixRoomSummary] = []
        for item in rosterItems {
            summaries.append(await roomSummary(for: item, accountJID: accountJID, connection: connection))
        }
        summaries.append(contentsOf: groupRoomSummaries(accountJID: accountJID, connection: connection))

        let sortedSummaries = Self.sortedRoomSummaries(summaries)
        try? roomSummaryCacheStore.save(sortedSummaries, accountJID: accountJID)
        return sortedSummaries
    }

    func cachedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let summaries = try roomSummaryCacheStore.load(accountJID: accountJID)
        return Self.sortedRoomSummaries(
            summaries.map { cachedSummary in
                cachedRoomSummary(cachedSummary, accountJID: accountJID)
            }
        )
    }

    private func roomSummary(
        for item: any RosterItemProtocol,
        accountJID: String,
        connection: Connection
    ) async -> TrixRoomSummary {
        let peerJID = item.jid.bareJid.stringValue
        let hasTrustedDevice = connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID)
        loadCachedTimelineItems(accountJID: accountJID, roomID: peerJID)

        if let archive = try? await archivedTimelineResult(peerJID: peerJID, accountJID: accountJID, connection: connection),
           !archive.items.isEmpty {
            storeTimelineItems(archive.items, accountJID: accountJID, roomID: peerJID)
        }

        let latestItem = timelineItems(accountJID: accountJID, roomID: peerJID).last
        return TrixRoomSummary(
            id: peerJID,
            name: item.name ?? Self.displayName(from: peerJID),
            kind: .direct,
            isEncrypted: hasTrustedDevice,
            unreadCount: 0,
            lastMessagePreview: Self.roomPreview(from: latestItem) ?? (hasTrustedDevice ? "Ready for OMEMO messages" : "Trust OMEMO device before sending"),
            lastActivityAt: latestItem?.timestamp ?? Date.distantPast
        )
    }

    private func cachedRoomSummary(_ summary: TrixRoomSummary, accountJID: String) -> TrixRoomSummary {
        _ = loadCachedTimelineItems(accountJID: accountJID, roomID: summary.id)
        guard let latestItem = timelineItems(accountJID: accountJID, roomID: summary.id).last else {
            return summary
        }

        return TrixRoomSummary(
            id: summary.id,
            name: summary.name,
            kind: summary.kind,
            isEncrypted: summary.isEncrypted,
            unreadCount: summary.unreadCount,
            lastMessagePreview: Self.roomPreview(from: latestItem) ?? summary.lastMessagePreview,
            lastActivityAt: max(summary.lastActivityAt, latestItem.timestamp)
        )
    }

    private func groupRoomSummaries(accountJID: String, connection: Connection) -> [TrixRoomSummary] {
        var groups = knownGroupRooms[accountJID.lowercased()] ?? [:]
        for room in connection.mucModule.roomManager.rooms(for: connection.client) {
            let roomID = room.jid.stringValue
            let roomKey = roomID.lowercased()
            let cached = groups[roomKey] ?? loadCachedGroup(roomID: roomID, accountJID: accountJID)
            groups[roomKey] = KnownGroupRoom(
                roomID: roomID,
                name: cached?.name ?? Self.displayName(from: roomID),
                memberUserIDs: cached?.memberUserIDs ?? Self.memberUserIDs(from: room, fallbackAccountJID: accountJID),
                lastActivityAt: cached?.lastActivityAt ?? Date()
            )
        }

        for bookmark in connection.bookmarksModule.currentBookmarks.items.compactMap({ $0 as? Bookmarks.Conference }) {
            guard bookmark.jid.bareJid.domain == XMPPClientConfiguration.conferenceServerName else {
                continue
            }

            let roomID = bookmark.jid.bareJid.stringValue
            let roomKey = roomID.lowercased()
            if groups[roomKey] == nil {
                let cached = loadCachedGroup(roomID: roomID, accountJID: accountJID)
                groups[roomKey] = KnownGroupRoom(
                    roomID: roomID,
                    name: bookmark.name ?? cached?.name ?? Self.displayName(from: roomID),
                    memberUserIDs: cached?.memberUserIDs ?? [accountJID.lowercased()],
                    lastActivityAt: cached?.lastActivityAt ?? Date.distantPast
                )
            }
        }

        knownGroupRooms[accountJID.lowercased()] = groups
        return groups.values.map { group in
            let latestItem = timelineItems(accountJID: accountJID, roomID: group.roomID).last
            return TrixRoomSummary(
                id: group.roomID,
                name: group.name,
                kind: .group,
                isEncrypted: true,
                unreadCount: 0,
                lastMessagePreview: Self.roomPreview(from: latestItem) ?? "Private OMEMO group",
                lastActivityAt: latestItem?.timestamp ?? group.lastActivityAt
            )
        }
    }

    func cachedTimeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        let peerJID = try Self.normalizedRoomID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        _ = loadCachedTimelineItems(accountJID: accountJID, roomID: peerJID)
        return timelineItems(accountJID: accountJID, roomID: peerJID)
    }

    func timeline(roomID: String, session: TrixSession) async throws -> [TrixTimelineItem] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedRoomID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let localCacheLoadedCount = loadCachedTimelineItems(accountJID: accountJID, roomID: peerJID)
        if Self.isMUCJID(peerJID) {
            _ = try? await joinedGroupRoom(roomID: peerJID, session: session, connection: connection)
        } else {
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
                        mamLocalKeyCount: archive.localKeyCount,
                        mamAccountSenderCount: archive.accountSenderCount,
                        mamAccountSenderMissingLocalKeyCount: archive.accountSenderMissingLocalKeyCount,
                        mamPeerSenderCount: archive.peerSenderCount,
                        localCacheLoadedCount: localCacheLoadedCount,
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
                        mamLocalKeyCount: 0,
                        mamAccountSenderCount: 0,
                        mamAccountSenderMissingLocalKeyCount: 0,
                        mamPeerSenderCount: 0,
                        localCacheLoadedCount: localCacheLoadedCount,
                        cachedCount: timelineItems(accountJID: accountJID, roomID: peerJID).count,
                        usedUnfilteredFallback: false
                    ),
                    accountJID: accountJID,
                    roomID: peerJID
                )
            }
        }

        return timelineItems(accountJID: accountJID, roomID: peerJID)
    }

    func timelineDiagnostics(roomID: String, session: TrixSession) async throws -> XMPPTimelineDiagnostics? {
        let peerJID = try Self.normalizedRoomID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        return timelineDiagnostics[accountJID.lowercased()]?[peerJID.lowercased()]
    }

    func sendText(_ text: String, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.emptyMessage
        }

        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedRoomID(roomID)
        if Self.isMUCJID(peerJID) {
            return try await sendGroupText(body, roomID: peerJID, session: session, connection: connection)
        }

        guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
            _ = try? await refreshPeerDeviceIdentities(userID: peerJID, session: session)
            guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
                throw TrixClientError.omemoDeviceTrustRequired
            }
            return try await sendText(body, roomID: roomID, session: session)
        }

        let messageID = "trix-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .chat
        message.to = JID(peerJID)
        message.body = body
        message.messageDelivery = .request

        let encryptedMessage = try await encodeOMEMOMessage(message, peerJID: peerJID, connection: connection)
        encryptedMessage.messageDelivery = .request
        guard encryptedMessage.body == nil,
              let encrypted = encryptedMessage.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS),
              let header = encrypted.firstChild(name: "header"),
              !header.filterChildren(name: "key", xmlns: nil).isEmpty else {
            throw TrixClientError.omemoEncryptionFailed
        }

        try await connection.omemoStack.module.write(stanza: encryptedMessage)

        let item = TrixTimelineItem(
            id: messageID,
            roomID: peerJID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true,
            attachment: nil,
            deliveryState: .sent
        )
        storeTimelineItems([item], accountJID: session.userID, roomID: peerJID)
        return item
    }

    func setReaction(_ emoji: String, messageID: String, roomID: String, session: TrixSession) async throws -> [TrixMessageReaction] {
        let normalizedEmoji = try Self.normalizedReactionEmoji(emoji)
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedRoomID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)

        _ = loadCachedTimelineItems(accountJID: accountJID, roomID: peerJID)
        guard let item = timelineItems(accountJID: accountJID, roomID: peerJID).first(where: { $0.id == messageID }) else {
            throw TrixClientError.roomUnavailable
        }

        if Self.isMUCJID(peerJID) {
            let room = try await joinedGroupRoom(roomID: peerJID, session: session, connection: connection)
            _ = try await validatedGroupEncryptionRecipients(
                room: room,
                accountJID: accountJID,
                session: session,
                connection: connection
            )
        } else {
            guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
                _ = try? await refreshPeerDeviceIdentities(userID: peerJID, session: session)
                guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
                    throw TrixClientError.omemoDeviceTrustRequired
                }
                return try await setReaction(normalizedEmoji, messageID: messageID, roomID: roomID, session: session)
            }
        }

        var ownEmojis = item.reactions
            .filter { $0.sender.caseInsensitiveCompare(accountJID) == .orderedSame }
            .map(\.emoji)
        if ownEmojis.contains(normalizedEmoji) {
            ownEmojis.removeAll { $0 == normalizedEmoji }
        } else {
            ownEmojis.append(normalizedEmoji)
        }
        ownEmojis = Self.uniqueReactionEmojis(ownEmojis)

        let reactionMessage = Self.reactionMessage(
            roomID: peerJID,
            messageID: messageID,
            emojis: ownEmojis,
            isGroup: Self.isMUCJID(peerJID)
        )
        if Self.isMUCJID(peerJID) {
            try await connection.mucModule.write(stanza: reactionMessage)
            updateGroupActivity(roomID: peerJID, accountJID: accountJID, at: Date())
        } else {
            try await connection.messageCaptureModule.write(stanza: reactionMessage)
        }

        return applyReactionUpdate(
            messageID: messageID,
            roomID: peerJID,
            senderJID: accountJID,
            emojis: ownEmojis,
            timestamp: Date(),
            accountJID: accountJID
        )
    }

    func sendAttachment(_ attachment: TrixAttachmentUpload, roomID: String, session: TrixSession) async throws -> TrixTimelineItem {
        guard !attachment.data.isEmpty else {
            throw TrixClientError.emptyAttachment
        }

        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedRoomID(roomID)
        if Self.isMUCJID(peerJID) {
            return try await sendGroupAttachment(attachment, roomID: peerJID, session: session, connection: connection)
        }

        guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
            _ = try? await refreshPeerDeviceIdentities(userID: peerJID, session: session)
            guard connection.omemoStack.store.hasTrustedActiveDevice(forName: peerJID) else {
                throw TrixClientError.omemoDeviceTrustRequired
            }
            return try await sendAttachment(attachment, roomID: roomID, session: session)
        }

        let encryptedMedia: (data: Data, fragment: String)
        switch connection.omemoStack.module.encryptFile(data: attachment.data) {
        case .success(let result):
            encryptedMedia = (data: result.0, fragment: result.1)
        case .failure:
            throw TrixClientError.attachmentEncryptionUnavailable
        }

        let uploadModule: HttpFileUploadModule = connection.client.modulesManager.module(.httpFileUpload)
        let uploadComponent = try await uploadModule.findHttpUploadComponents()
            .filter { $0.maxSize >= encryptedMedia.data.count }
            .sorted { $0.maxSize < $1.maxSize }
            .first
        guard let uploadComponent else {
            throw TrixClientError.attachmentTransferFailed
        }

        let encryptedFilename = "trix-\(UUID().uuidString).enc"
        let slot = try await uploadModule.requestUploadSlot(
            componentJid: uploadComponent.jid,
            filename: encryptedFilename,
            size: encryptedMedia.data.count,
            contentType: "application/octet-stream"
        )
        try await uploadEncryptedAttachment(encryptedMedia.data, slot: slot)

        let descriptor = EncryptedAttachmentDescriptor(
            type: Self.encryptedAttachmentDescriptorType,
            version: 1,
            downloadURL: slot.getUri.absoluteString,
            fragment: encryptedMedia.fragment,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            originalSizeBytes: attachment.data.count,
            encryptedSizeBytes: encryptedMedia.data.count,
            imageDimensions: attachment.imageDimensions,
            imageBlurhash: attachment.imageBlurhash,
            stickerMetadata: attachment.stickerMetadata
        )
        let descriptorJSON = try Self.encodedAttachmentDescriptor(descriptor)

        let messageID = "trix-attachment-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .chat
        message.to = JID(peerJID)
        message.body = descriptorJSON
        message.messageDelivery = MessageDeliveryReceiptEnum.request

        let encryptedMessage = try await encodeOMEMOMessage(message, peerJID: peerJID, connection: connection)
        encryptedMessage.messageDelivery = MessageDeliveryReceiptEnum.request
        guard encryptedMessage.body == nil,
              let encrypted = encryptedMessage.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS),
              let header = encrypted.firstChild(name: "header"),
              !header.filterChildren(name: "key", xmlns: nil as String?).isEmpty else {
            throw TrixClientError.omemoEncryptionFailed
        }

        try await connection.omemoStack.module.write(stanza: encryptedMessage)

        let item = TrixTimelineItem(
            id: messageID,
            roomID: peerJID,
            sender: session.userID,
            timestamp: Date(),
            body: Self.attachmentTimelineBody(for: attachment),
            isLocalEcho: true,
            attachment: Self.timelineAttachment(from: descriptor, sourceJSON: descriptorJSON),
            deliveryState: .sent
        )
        storeTimelineItems([item], accountJID: session.userID, roomID: peerJID)
        return item
    }

    func attachmentSendAvailability(roomID: String, session: TrixSession) async throws -> TrixAttachmentSendAvailability {
        let connection = try await ensureConnection(for: session)
        let normalizedRoomID = try Self.normalizedRoomID(roomID)

        if Self.isMUCJID(normalizedRoomID) {
            let room = try await joinedGroupRoom(roomID: normalizedRoomID, session: session, connection: connection)
            let accountJID = try Self.normalizedXMPPJID(session.userID)

            do {
                let recipients = try await validatedGroupEncryptionRecipients(
                    room: room,
                    accountJID: accountJID,
                    session: session,
                    connection: connection
                )
                return .allowed(roomID: normalizedRoomID, recipientUserIDs: recipients)
            } catch TrixClientError.groupOmemoRecipientSetUnavailable {
                return .blocked(roomID: normalizedRoomID, reason: .groupRecipientSetUnavailable)
            } catch TrixClientError.groupOmemoDeviceTrustRequired {
                return .blocked(roomID: normalizedRoomID, reason: .groupOmemoDeviceTrustRequired)
            } catch TrixClientError.omemoDeviceTrustRequired {
                return .blocked(roomID: normalizedRoomID, reason: .groupOmemoDeviceTrustRequired)
            }
        }

        guard connection.omemoStack.store.hasTrustedActiveDevice(forName: normalizedRoomID) else {
            _ = try? await refreshPeerDeviceIdentities(userID: normalizedRoomID, session: session)
            guard connection.omemoStack.store.hasTrustedActiveDevice(forName: normalizedRoomID) else {
                return .blocked(roomID: normalizedRoomID, reason: .omemoDeviceTrustRequired)
            }
            return .allowed(roomID: normalizedRoomID, recipientUserIDs: [normalizedRoomID])
        }

        return .allowed(roomID: normalizedRoomID, recipientUserIDs: [normalizedRoomID])
    }

    func downloadAttachment(_ attachment: TrixTimelineAttachment, session: TrixSession) async throws -> TrixAttachmentDownload {
        let connection = try await ensureConnection(for: session)
        guard let descriptor = Self.decodedAttachmentDescriptor(from: attachment.sourceJSON),
              let url = URL(string: descriptor.downloadURL) else {
            throw TrixClientError.attachmentDownloadUnavailable
        }

        let encryptedData = try await downloadEncryptedAttachment(from: url)
        switch connection.omemoStack.module.decryptFile(data: encryptedData, fragment: descriptor.fragment) {
        case .success(let data):
            return TrixAttachmentDownload(
                filename: descriptor.filename,
                mimeType: descriptor.mimeType,
                data: data
            )
        case .failure:
            throw TrixClientError.attachmentDecryptionFailed
        }
    }

    func callDescriptors(roomID: String, session: TrixSession) async throws -> [TrixReceivedCallDescriptor] {
        let normalizedRoomID = try Self.normalizedRoomID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        _ = try await timeline(roomID: normalizedRoomID, session: session)
        return callDescriptorItems(accountJID: accountJID, roomID: normalizedRoomID)
    }

    func sendCallInvite(
        _ invite: TrixCallInvite,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try await sendCallDescriptor(.invite(invite), roomID: roomID, session: session)
    }

    func sendCallAnswer(
        _ answer: TrixCallAnswer,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try await sendCallDescriptor(.answer(answer), roomID: roomID, session: session)
    }

    func sendCallEnd(
        _ end: TrixCallEnd,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try await sendCallDescriptor(.end(end), roomID: roomID, session: session)
    }

    func sendVoiceRoomState(
        _ state: TrixVoiceRoomState,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try await sendCallDescriptor(.voiceRoomState(state), roomID: roomID, session: session)
    }

    func sendCallKeyRotation(
        _ rotation: TrixCallKeyRotation,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        try await sendCallDescriptor(.keyRotation(rotation), roomID: roomID, session: session)
    }

    func typingState(roomID: String, session: TrixSession) async throws -> TrixRoomTypingState {
        _ = try await ensureConnection(for: session)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let peerJID = try Self.normalizedXMPPJID(roomID)
        pruneTypingRecords(accountJID: accountJID, roomID: peerJID)

        let records = typingRecords[accountJID.lowercased()]?[peerJID.lowercased()] ?? [:]
        let typingUserIDs = records.values
            .filter { $0.state == .composing }
            .map(\.userID)
            .sorted()

        return TrixRoomTypingState(
            roomID: peerJID,
            typingUserIDs: typingUserIDs,
            updatedAt: Date()
        )
    }

    func sendTypingState(_ state: TrixTypingState, roomID: String, session: TrixSession) async throws {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(roomID)

        let message = Message()
        message.id = "trix-chatstate-\(UUID().uuidString)"
        message.type = .chat
        message.to = JID(peerJID)
        message.chatState = Self.chatState(from: state)
        message.hints = [.noStore, .noCopy]

        try await connection.chatStateModule.write(stanza: message)
    }

    func members(roomID: String, session: TrixSession) async throws -> [TrixRoomMember] {
        let peerJID = try Self.normalizedRoomID(roomID)
        if Self.isMUCJID(peerJID) {
            let connection = try await ensureConnection(for: session)
            let room = try await joinedGroupRoom(roomID: peerJID, session: session, connection: connection)
            let accountJID = try Self.normalizedXMPPJID(session.userID)
            let members = try await groupMembers(room: room, accountJID: accountJID, connection: connection)
            cacheGroupMembers(members.map(\.userID), roomID: peerJID, accountJID: accountJID, name: nil)
            return members
        }

        return [
            TrixRoomMember(userID: session.userID, displayName: Self.displayName(from: session.userID), membership: .joined),
            TrixRoomMember(userID: peerJID, displayName: Self.displayName(from: peerJID), membership: .joined),
        ]
    }

    func inviteUser(_ userID: String, roomID: String, session: TrixSession) async throws {
        let connection = try await ensureConnection(for: session)
        let inviteeJID = try Self.normalizedXMPPJID(userID)
        let normalizedRoomID = try Self.normalizedRoomID(roomID)
        guard Self.isMUCJID(normalizedRoomID) else {
            throw TrixClientError.roomUnavailable
        }

        let room = try await joinedGroupRoom(roomID: normalizedRoomID, session: session, connection: connection)
        try await setGroupAffiliations(
            [MucModule.RoomAffiliation(jid: JID(inviteeJID), affiliation: .admin)],
            room: room,
            connection: connection
        )
        try await connection.mucModule.invite(to: room, invitee: JID(inviteeJID), reason: "Trix private group invite")
        cacheGroupMembers([inviteeJID], roomID: normalizedRoomID, accountJID: session.userID, name: nil)
    }

    func removeUser(_ userID: String, roomID: String, session: TrixSession) async throws {
        let connection = try await ensureConnection(for: session)
        let removedJID = try Self.normalizedXMPPJID(userID)
        let normalizedRoomID = try Self.normalizedRoomID(roomID)
        guard Self.isMUCJID(normalizedRoomID) else {
            throw TrixClientError.roomUnavailable
        }

        let room = try await joinedGroupRoom(roomID: normalizedRoomID, session: session, connection: connection)
        try await setGroupAffiliations(
            [MucModule.RoomAffiliation(jid: JID(removedJID), affiliation: .none)],
            room: room,
            connection: connection
        )
        removeCachedGroupMember(removedJID, roomID: normalizedRoomID, accountJID: session.userID)
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(inviteeUserID)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.displayName(from: peerJID) : name
        try await ensureDirectRosterItem(peerJID: peerJID, displayName: displayName, connection: connection)

        return TrixRoomSummary(
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
        session: TrixSession
    ) async throws -> TrixRoomSummary {
        let connection = try await ensureConnection(for: session)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.groupRoomNameRequired
        }
        let invitees = try Self.normalizedGroupInvitees(inviteeUserIDs, excluding: session.userID)
        guard invitees.count >= 2 else {
            throw TrixClientError.groupInviteesRequired
        }
        let roomName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomLocalpart = Self.groupRoomLocalpart(from: roomName)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let joinResult = try await connection.mucModule.join(
            roomName: roomLocalpart,
            mucServer: XMPPClientConfiguration.conferenceServerName,
            nickname: Self.mucNickname(from: accountJID),
            password: nil
        )
        let room = Self.room(from: joinResult)
        try await configurePrivateGroupRoom(room: room, name: roomName, inviteeUserIDs: invitees, ownerJID: accountJID, connection: connection)
        for invitee in invitees {
            try await connection.mucModule.invite(to: room, invitee: JID(invitee), reason: "Trix private group invite")
        }

        let roomID = room.jid.stringValue
        cacheGroupMembers([accountJID] + invitees, roomID: roomID, accountJID: accountJID, name: roomName)
        try? await bookmarkGroupRoom(roomID: roomID, name: roomName, nickname: Self.mucNickname(from: accountJID), connection: connection)
        return TrixRoomSummary(
            id: roomID,
            name: roomName,
            kind: .group,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "Trust OMEMO devices for every member before sending",
            lastActivityAt: Date()
        )
    }

    func invitations(session: TrixSession) async throws -> [TrixRoomInvite] {
        let connection = try await ensureConnection(for: session)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        try loadPersistedGroupInvitationState(accountJID: accountJID)
        await syncArchivedGroupInvitationsIfNeeded(accountJID: accountJID, connection: connection)

        return pendingGroupInvitations[accountJID.lowercased(), default: [:]]
            .values
            .map { invitation in
                TrixRoomInvite(
                    id: invitation.roomID,
                    roomName: invitation.roomName,
                    kind: .group,
                    isEncrypted: true,
                    inviterUserID: invitation.inviterUserID,
                    inviterDisplayName: invitation.inviterUserID.map(Self.displayName(from:)),
                    receivedAt: invitation.receivedAt
                )
            }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    func acceptInvitation(roomID: String, session: TrixSession) async throws -> TrixRoomSummary {
        let connection = try await ensureConnection(for: session)
        let normalizedRoomID = try Self.normalizedMUCJID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let accountKey = accountJID.lowercased()
        try loadPersistedGroupInvitationState(accountJID: accountJID)
        let invitation = pendingGroupInvitations[accountKey]?[normalizedRoomID.lowercased()]
        let summary = try await joinGroupRoom(
            roomID: normalizedRoomID,
            displayName: invitation?.roomName,
            password: invitation?.password,
            session: session,
            connection: connection
        )
        markGroupInvitationDismissed(roomID: normalizedRoomID, accountJID: accountJID, at: Date())
        try persistGroupInvitationState(accountJID: accountJID)
        return summary
    }

    func declineInvitation(roomID: String, session: TrixSession) async throws {
        let connection = try await ensureConnection(for: session)
        let normalizedRoomID = try Self.normalizedMUCJID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let accountKey = accountJID.lowercased()
        try loadPersistedGroupInvitationState(accountJID: accountJID)
        await syncArchivedGroupInvitationsIfNeeded(accountJID: accountJID, connection: connection)
        guard let invitation = pendingGroupInvitations[accountKey]?[normalizedRoomID.lowercased()] else {
            throw TrixClientError.inviteUnavailable
        }

        if invitation.transport == .mediated {
            try await declineMediatedGroupInvitation(invitation, connection: connection)
        }

        markGroupInvitationDismissed(roomID: normalizedRoomID, accountJID: accountJID, at: Date())
        try persistGroupInvitationState(accountJID: accountJID)
    }

    func joinRoom(roomID: String, session: TrixSession) async throws -> TrixRoomSummary {
        let roomJID = try Self.normalizedRoomID(roomID)
        let connection = try await ensureConnection(for: session)
        if Self.isMUCJID(roomJID) {
            return try await joinGroupRoom(roomID: roomJID, displayName: nil, password: nil, session: session, connection: connection)
        }

        try await ensureDirectRosterItem(peerJID: roomJID, displayName: Self.displayName(from: roomJID), connection: connection)
        return TrixRoomSummary(
            id: roomJID,
            name: Self.displayName(from: roomJID),
            kind: .direct,
            isEncrypted: false,
            unreadCount: 0,
            lastMessagePreview: "OMEMO setup required before sending",
            lastActivityAt: Date()
        )
    }

    func joinInvitedRooms(session: TrixSession) async throws -> [TrixRoomSummary] {
        let invitations = try await invitations(session: session)
        var rooms: [TrixRoomSummary] = []
        for invitation in invitations {
            rooms.append(try await acceptInvitation(roomID: invitation.id, session: session))
        }
        return rooms
    }

    func deviceVerificationStatus(session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        let connection = try await ensureConnection(for: session)
        let registrationID = connection.omemoStack.store.localRegistrationId()
        let localAddress = SignalAddress(name: session.userID, deviceId: Int32(bitPattern: registrationID))
        let fingerprint = connection.omemoStack.store.identityFingerprint(forAddress: localAddress)

        return TrixDeviceVerificationStatus(
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

    func deviceVerificationFlow(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        return .idle
    }

    func peerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(userID)
        return Self.peerDeviceIdentities(from: connection.omemoStack.store.identities(forName: peerJID), userID: peerJID)
    }

    func refreshPeerDeviceIdentities(userID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(userID)
        let bareJID = BareJID(peerJID)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.omemoStack.module.addresses(for: [bareJID]) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure:
                    continuation.resume(throwing: TrixClientError.e2eeUnavailable)
                }
            }
        }

        return Self.peerDeviceIdentities(from: connection.omemoStack.store.identities(forName: peerJID), userID: peerJID)
    }

    func trustPeerDevice(userID: String, deviceID: String, session: TrixSession) async throws -> [TrixPeerDeviceIdentity] {
        let connection = try await ensureConnection(for: session)
        let peerJID = try Self.normalizedXMPPJID(userID)
        if !connection.omemoStack.store.trustIdentity(forName: peerJID, deviceID: deviceID) {
            _ = try await refreshPeerDeviceIdentities(userID: peerJID, session: session)
            guard connection.omemoStack.store.trustIdentity(forName: peerJID, deviceID: deviceID) else {
                throw TrixClientError.omemoDeviceTrustRequired
            }
        }

        return Self.peerDeviceIdentities(from: connection.omemoStack.store.identities(forName: peerJID), userID: peerJID)
    }

    func requestDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func acceptDeviceVerificationRequest(
        _ request: TrixDeviceVerificationRequest,
        session: TrixSession
    ) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func startSasDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func approveDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func declineDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func cancelDeviceVerification(session: TrixSession) async throws -> TrixDeviceVerificationFlow {
        _ = try await ensureConnection(for: session)
        return .idle
    }

    func setUpRecovery(session: TrixSession) async throws -> String {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func confirmRecoveryKey(_ recoveryKey: String, session: TrixSession) async throws -> TrixDeviceVerificationStatus {
        _ = try await ensureConnection(for: session)
        throw TrixClientError.e2eeUnavailable
    }

    func searchUsers(
        _ searchTerm: String,
        limit: Int,
        session: TrixSession
    ) async throws -> TrixUserSearchResult {
        let connection = try await refreshedRosterConnection(for: session)

        let rosterUsers = connection.rosterModule.rosterManager
            .items(for: connection.client)
            .map { item in
                TrixUserProfile(
                    userID: item.jid.bareJid.stringValue,
                    displayName: item.name,
                    avatarURL: nil
                )
            }

        var users = rosterUsers + (try await searchDirectoryUsers(searchTerm, limit: limit, connection: connection))
        if let directJID = try? Self.normalizedXMPPJID(searchTerm),
           !users.contains(where: { $0.userID.lowercased() == directJID.lowercased() }) {
            users.append(TrixUserProfile(userID: directJID, displayName: Self.displayName(from: directJID), avatarURL: nil))
        }

        let needle = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let uniqueUsers = Self.deduplicatedUsers(users)
        let filtered = needle.isEmpty
            ? uniqueUsers
            : uniqueUsers.filter { user in
                user.userID.lowercased().contains(needle)
                    || (user.displayName?.lowercased().contains(needle) == true)
            }

        return TrixUserSearchResult(users: Array(filtered.prefix(max(limit, 0))), limited: filtered.count > limit)
    }

    func profile(userID: String, session: TrixSession) async throws -> TrixUserProfile {
        let connection = try await ensureConnection(for: session)
        let jid = try Self.normalizedXMPPJID(userID)
        let vCard = try? await retrieveVCardElement(for: jid, connection: connection)
        return Self.profile(from: vCard, userID: jid)
    }

    func updateDisplayName(_ displayName: String, session: TrixSession) async throws -> TrixUserProfile {
        let connection = try await ensureConnection(for: session)
        let jid = try Self.normalizedXMPPJID(session.userID)
        let currentVCard = try? await retrieveVCardElement(for: jid, connection: connection)
        let currentProfile = Self.profile(from: currentVCard, userID: jid)
        return try await updateProfile(
            TrixUserProfileUpdate(
                displayName: displayName,
                bio: currentProfile.metadata.bio ?? "",
                statusMessage: currentProfile.metadata.statusMessage ?? "",
                website: currentProfile.metadata.website ?? ""
            ),
            session: session
        )
    }

    func updateProfile(_ update: TrixUserProfileUpdate, session: TrixSession) async throws -> TrixUserProfile {
        let connection = try await ensureConnection(for: session)
        let jid = try Self.normalizedXMPPJID(session.userID)
        let currentVCard = try? await retrieveVCardElement(for: jid, connection: connection)
        let updatedVCard = Self.updatingVCard(currentVCard, userID: jid, update: update)
        try await publishVCardElement(updatedVCard, connection: connection)
        return Self.profile(from: updatedVCard, userID: jid)
    }

    private func sendClientState(isActive: Bool, connection: Connection) async {
        guard connection.csiModule.available,
              connection.applicationIsActive != isActive else {
            return
        }

        let element = Element(
            name: isActive ? "active" : "inactive",
            xmlns: ClientStateIndicationModule.CSI_XMLNS
        )
        let stanza = Stanza.from(element: element)

        do {
            try await connection.csiModule.write(stanza: stanza)
            connection.applicationIsActive = isActive
        } catch {
            connection.applicationIsActive = nil
        }
    }

    private func ensureConnection(for session: TrixSession) async throws -> Connection {
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

    private func refreshedRosterConnection(for session: TrixSession) async throws -> Connection {
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

    private func reconnect(for session: TrixSession) async throws -> Connection {
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
                guard let message = Self.detachedMessage(message) else {
                    return
                }

                let capturedMessage = CapturedMessage(
                    message: message,
                    accountJID: connection.client.connectionConfiguration.userJid.stringValue,
                    carbonAction: nil
                )
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
                guard let message = Self.detachedMessage(carbon.message) else {
                    return
                }

                let capturedMessage = CapturedMessage(
                    message: message,
                    accountJID: connection.client.connectionConfiguration.userJid.stringValue,
                    carbonAction: carbon.action
                )
                Task {
                    await service.recordLiveMessage(capturedMessage, connection: connection)
                }
            }
            .store(in: &connection.cancellables)

        connection.deliveryReceiptsModule.receiptsPublisher
            .sink { [weak connection] receipt in
                guard let connection else {
                    return
                }

                let capturedReceipt = CapturedDeliveryReceipt(
                    messageID: receipt.messageId,
                    roomID: Self.deliveryReceiptRoomID(
                        from: receipt.message,
                        accountJID: connection.client.connectionConfiguration.userJid.stringValue
                    )
                )
                Task {
                    await service.recordDeliveryReceipt(capturedReceipt, connection: connection)
                }
            }
            .store(in: &connection.cancellables)

        connection.mucModule.inivitationsPublisher
            .sink { [weak connection] invitation in
                guard let connection else {
                    return
                }

                let capturedInvitation = CapturedMUCInvitation(
                    roomID: invitation.roomJid.stringValue,
                    roomName: Self.displayName(from: invitation.roomJid.stringValue),
                    inviterUserID: invitation.inviter?.bareJid.stringValue,
                    password: invitation.password,
                    reason: invitation.reason,
                    receivedAt: Date(),
                    transport: Self.mucInvitationTransport(from: invitation)
                )
                Task {
                    await service.recordGroupInvitation(capturedInvitation, connection: connection)
                }
            }
            .store(in: &connection.cancellables)

        connection.mucModule.messagesPublisher
            .sink { [weak connection] event in
                guard let connection else {
                    return
                }
                guard let message = Self.detachedMessage(event.message) else {
                    return
                }
                let accountJID = connection.client.connectionConfiguration.userJid.stringValue

                let capturedMessage = CapturedMUCMessage(
                    roomID: event.room.jid.stringValue,
                    senderJID: Self.groupMessageSenderJID(event.message, room: event.room, accountJID: accountJID),
                    knownMemberUserIDs: Self.memberUserIDs(from: event.room, fallbackAccountJID: accountJID),
                    message: message
                )
                Task {
                    await service.recordGroupMessage(capturedMessage, connection: connection)
                }
            }
            .store(in: &connection.cancellables)
    }

    private func openConnection(for session: TrixSession) async throws -> Connection {
        let jid = try Self.normalizedXMPPJID(session.userID)
        guard !session.accessToken.isEmpty else {
            throw TrixClientError.missingSession
        }

        let connection = try makeConnection(jid: jid, password: session.accessToken, resource: session.deviceID)
        do {
            try await loginAndWait(client: connection.client)
        } catch {
            throw TrixClientError.xmppConnectionFailed
        }
        await waitForOMEMOReady(connection: connection)
        await replaceConnection(connection, for: session)
        try? await connection.carbonsModule.enable()
        try? await publishDirectoryProfileIfNeeded(session: session, connection: connection)
        return connection
    }

    private func replaceConnection(_ connection: Connection, for session: TrixSession) async {
        let key = Self.sessionKey(session)
        if let existing = connections[key] {
            try? await existing.client.disconnect(force: true)
        }
        installTimelineSubscriptions(for: connection)
        connections[key] = connection
    }

    private func loginAndWait(client: XMPPClient) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let waitState = XMPPLoginWaitState(continuation: continuation, client: client)
            waitState.retain(
                client.$state.dropFirst().sink { state in
                    switch state {
                    case .connected:
                        waitState.resumeReturning()
                    case .disconnected(let error):
                        waitState.resumeThrowing(error, disconnect: false)
                    default:
                        break
                    }
                }
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + Self.xmppConnectionTimeout) {
                waitState.resumeThrowing(XMPPError.remote_server_timeout, disconnect: true)
            }

            client.login()
        }
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

        var items: [TrixTimelineItem] = []
        var reactionUpdates: [CapturedReactionUpdate] = []
        var encryptedCount = 0
        var localKeyCount = 0
        var accountSenderCount = 0
        var accountSenderMissingLocalKeyCount = 0
        var peerSenderCount = 0
        let localDeviceID = String(connection.omemoStack.store.localRegistrationId())
        let accountKey = accountJID.lowercased()
        let peerKey = peerJID.lowercased()
        for archived in events {
            if archived.message.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS) != nil {
                encryptedCount += 1
            }
            let hasLocalKey = Self.messageHasRecipientKey(archived.message, recipientDeviceID: localDeviceID)
            if hasLocalKey {
                localKeyCount += 1
            }
            switch archived.message.from?.bareJid.stringValue.lowercased() {
            case accountKey:
                accountSenderCount += 1
                if !hasLocalKey {
                    accountSenderMissingLocalKeyCount += 1
                }
            case peerKey:
                peerSenderCount += 1
            default:
                break
            }
            if let reaction = Self.capturedReactionUpdate(
                from: archived.message,
                accountJID: accountJID,
                roomID: peerJID,
                senderJID: nil,
                carbonAction: nil,
                timestamp: archived.timestamp
            ) {
                reactionUpdates.append(reaction)
                continue
            }

            if let item = timelineItem(
                from: archived.message,
                accountJID: accountJID,
                roomID: peerJID,
                timestamp: archived.timestamp,
                fallbackID: archived.messageID,
                connection: connection
            ) {
                items.append(item)
            }
        }
        for reactionUpdate in reactionUpdates {
            items = Self.applyingReactionUpdate(reactionUpdate, to: items, accountJID: accountJID)
        }

        return ArchivedTimelineResult(
            items: items,
            rawCount: rawCount,
            filteredCount: events.count,
            encryptedCount: encryptedCount,
            localKeyCount: localKeyCount,
            accountSenderCount: accountSenderCount,
            accountSenderMissingLocalKeyCount: accountSenderMissingLocalKeyCount,
            peerSenderCount: peerSenderCount,
            usedUnfilteredFallback: usedUnfilteredFallback
        )
    }

    private func archiveEvents(peerJID: String?, connection: Connection) async throws -> [ArchivedMessageSnapshot] {
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
        let accountJID = capturedMessage.accountJID
        if let chatState = message.chatState {
            recordChatState(
                chatState,
                from: message,
                accountJID: accountJID,
                carbonAction: capturedMessage.carbonAction
            )
        }

        guard let roomID = Self.roomID(for: message, accountJID: accountJID, carbonAction: capturedMessage.carbonAction) else {
            return
        }

        if let reaction = Self.capturedReactionUpdate(
            from: message,
            accountJID: accountJID,
            roomID: roomID,
            senderJID: nil,
            carbonAction: capturedMessage.carbonAction,
            timestamp: Self.messageTimestamp(message, fallback: Date())
        ) {
            _ = applyReactionUpdate(reaction, accountJID: accountJID)
            return
        }

        guard let item = timelineItem(
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

    private func recordGroupInvitation(
        _ invitation: CapturedMUCInvitation,
        connection: Connection,
        persist: Bool = true
    ) async {
        let accountJID = connection.client.connectionConfiguration.userJid.stringValue
        let accountKey = accountJID.lowercased()
        guard let normalizedInvitation = Self.normalizedCapturedMUCInvitation(invitation) else {
            return
        }

        let roomKey = normalizedInvitation.roomID.lowercased()
        if let dismissedAt = dismissedGroupInvitations[accountKey]?[roomKey],
           normalizedInvitation.receivedAt <= dismissedAt {
            return
        }

        var accountInvitations = pendingGroupInvitations[accountKey] ?? [:]
        if let existing = accountInvitations[roomKey],
           existing.receivedAt > normalizedInvitation.receivedAt {
            return
        }

        accountInvitations[roomKey] = normalizedInvitation
        pendingGroupInvitations[accountKey] = accountInvitations
        cacheGroupMembers([accountJID], roomID: normalizedInvitation.roomID, accountJID: accountJID, name: normalizedInvitation.roomName)
        if persist {
            try? persistGroupInvitationState(accountJID: accountJID)
        }
    }

    private func loadPersistedGroupInvitationState(accountJID: String) throws {
        let state = try mucInvitationCacheStore.load(accountJID: accountJID)
        let accountKey = accountJID.lowercased()
        var dismissed = dismissedGroupInvitations[accountKey] ?? [:]
        for record in state.dismissed {
            let roomKey = record.roomID.lowercased()
            if let existing = dismissed[roomKey], existing >= record.dismissedAt {
                continue
            }
            dismissed[roomKey] = record.dismissedAt
        }
        dismissedGroupInvitations[accountKey] = dismissed

        var pending = pendingGroupInvitations[accountKey] ?? [:]
        for invitation in state.pending {
            guard let normalizedInvitation = Self.normalizedCapturedMUCInvitation(invitation) else {
                continue
            }

            let roomKey = normalizedInvitation.roomID.lowercased()
            if let dismissedAt = dismissed[roomKey],
               normalizedInvitation.receivedAt <= dismissedAt {
                continue
            }
            if let existing = pending[roomKey],
               existing.receivedAt > normalizedInvitation.receivedAt {
                continue
            }
            pending[roomKey] = normalizedInvitation
        }
        pendingGroupInvitations[accountKey] = pending
    }

    private func syncArchivedGroupInvitationsIfNeeded(accountJID: String, connection: Connection) async {
        let accountKey = accountJID.lowercased()
        guard invitationArchiveSyncConnectionDates[accountKey] != connection.createdAt else {
            return
        }
        invitationArchiveSyncConnectionDates[accountKey] = connection.createdAt

        guard let archivedEvents = try? await archiveEvents(peerJID: nil, connection: connection) else {
            return
        }

        for archived in archivedEvents {
            guard let invitation = Self.capturedMUCInvitation(
                from: archived.message,
                receivedAt: archived.timestamp
            ) else {
                continue
            }
            await recordGroupInvitation(invitation, connection: connection, persist: false)
        }

        try? persistGroupInvitationState(accountJID: accountJID)
    }

    private func persistGroupInvitationState(accountJID: String) throws {
        let accountKey = accountJID.lowercased()
        let pending = (pendingGroupInvitations[accountKey] ?? [:])
            .values
            .sorted { $0.receivedAt > $1.receivedAt }
        let dismissed = (dismissedGroupInvitations[accountKey] ?? [:])
            .map { DismissedMUCInvitation(roomID: $0.key, dismissedAt: $0.value) }
            .sorted { $0.dismissedAt > $1.dismissedAt }
            .prefix(200)
        let state = StoredMUCInvitationState(version: 1, pending: pending, dismissed: Array(dismissed))
        try mucInvitationCacheStore.save(state, accountJID: accountJID)
    }

    private func markGroupInvitationDismissed(roomID: String, accountJID: String, at date: Date) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        pendingGroupInvitations[accountKey]?.removeValue(forKey: roomKey)
        var dismissed = dismissedGroupInvitations[accountKey] ?? [:]
        if let existing = dismissed[roomKey], existing >= date {
            return
        }
        dismissed[roomKey] = date
        dismissedGroupInvitations[accountKey] = dismissed
    }

    private func declineMediatedGroupInvitation(
        _ invitation: CapturedMUCInvitation,
        connection: Connection
    ) async throws {
        guard let context = connection.mucModule.context else {
            throw TrixClientError.xmppConnectionFailed
        }

        let inviterJID: JID?
        if let inviterUserID = invitation.inviterUserID {
            inviterJID = JID(inviterUserID)
        } else {
            inviterJID = nil
        }

        let mediatedInvitation = MucModule.MediatedInvitation(
            context: context,
            message: Message(),
            roomJid: BareJID(invitation.roomID),
            inviter: inviterJID,
            reason: invitation.reason,
            password: invitation.password
        )
        try await connection.mucModule.decline(invitation: mediatedInvitation, reason: "Declined in Trix")
    }

    private func recordGroupMessage(
        _ capturedMessage: CapturedMUCMessage,
        connection: Connection
    ) async {
        let message = capturedMessage.message
        let accountJID = connection.client.connectionConfiguration.userJid.stringValue
        let roomID = capturedMessage.roomID
        let senderJID = capturedMessage.senderJID

        if let senderJID,
           let reaction = Self.capturedReactionUpdate(
            from: message,
            accountJID: accountJID,
            roomID: roomID,
            senderJID: senderJID,
            carbonAction: nil,
            timestamp: Self.messageTimestamp(message, fallback: Date())
        ) {
            _ = applyReactionUpdate(reaction, accountJID: accountJID)
            cacheGroupMembers([senderJID.lowercased()], roomID: roomID, accountJID: accountJID, name: nil)
            return
        }

        guard let item = timelineItem(
            from: message,
            accountJID: accountJID,
            roomID: roomID,
            timestamp: Self.messageTimestamp(message, fallback: Date()),
            fallbackID: nil,
            connection: connection,
            senderJID: senderJID
        ) else {
            return
        }

        var knownMembers = capturedMessage.knownMemberUserIDs
        if let senderJID {
            knownMembers.insert(senderJID.lowercased())
        }
        cacheGroupMembers(knownMembers, roomID: roomID, accountJID: accountJID, name: nil)
        storeTimelineItems([item], accountJID: accountJID, roomID: roomID)
        updateGroupActivity(roomID: roomID, accountJID: accountJID, at: item.timestamp)
    }

    private func recordChatState(
        _ chatState: ChatState,
        from message: Message,
        accountJID: String,
        carbonAction: MessageCarbonsModule.Action?
    ) {
        guard let roomID = Self.roomID(for: message, accountJID: accountJID, carbonAction: carbonAction),
              let senderJID = message.from?.bareJid.stringValue,
              senderJID.lowercased() != accountJID.lowercased() else {
            return
        }

        updateTypingRecord(
            accountJID: accountJID,
            roomID: roomID,
            senderJID: senderJID,
            state: Self.typingState(from: chatState)
        )
    }

    private func recordDeliveryReceipt(
        _ receipt: CapturedDeliveryReceipt,
        connection: Connection
    ) async {
        guard !receipt.messageID.isEmpty else {
            return
        }

        let accountJID = connection.client.connectionConfiguration.userJid.stringValue
        if let roomID = receipt.roomID,
           updateTimelineDeliveryState(
            accountJID: accountJID,
            roomID: roomID,
            messageID: receipt.messageID,
            deliveryState: .delivered
           ) {
            return
        }

        _ = updateTimelineDeliveryState(
            accountJID: accountJID,
            roomID: nil,
            messageID: receipt.messageID,
            deliveryState: .delivered
        )
    }

    private func timelineItem(
        from message: Message,
        accountJID: String,
        roomID: String,
        timestamp: Date,
        fallbackID: String?,
        connection: Connection,
        senderJID: String? = nil
    ) -> TrixTimelineItem? {
        guard message.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS) != nil else {
            return nil
        }

        let decoded: Message
        let decodeResult = senderJID
            .map { connection.omemoStack.module.decode(message: message, from: BareJID($0), serverMsgId: fallbackID) }
            ?? connection.omemoStack.module.decode(message: message, serverMsgId: fallbackID)
        switch decodeResult {
        case .successMessage(let decryptedMessage, _):
            decoded = decryptedMessage
        case .successTransportKey, .failure:
            return nil
        }

        guard let body = decoded.body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            return nil
        }

        let resolvedSenderJID = senderJID ?? decoded.from?.bareJid.stringValue ?? roomID
        let normalizedAccountJID = accountJID.lowercased()
        let isLocalEcho = resolvedSenderJID.lowercased() == normalizedAccountJID
        if let descriptor = Self.decodedCallDescriptor(from: body) {
            let item = TrixReceivedCallDescriptor(
                id: decoded.id ?? fallbackID ?? "xmpp-call-\(UUID().uuidString)",
                roomID: roomID,
                senderID: isLocalEcho ? accountJID : resolvedSenderJID,
                timestamp: timestamp,
                descriptor: descriptor,
                isLocalEcho: isLocalEcho
            )
            storeCallDescriptors([item], accountJID: accountJID, roomID: roomID)
            return nil
        }

        let content = Self.decodedTimelineContent(from: body)
        return TrixTimelineItem(
            id: decoded.id ?? fallbackID ?? "xmpp-\(UUID().uuidString)",
            roomID: roomID,
            sender: isLocalEcho ? accountJID : resolvedSenderJID,
            timestamp: timestamp,
            body: content.body,
            isLocalEcho: isLocalEcho,
            attachment: content.attachment,
            deliveryState: isLocalEcho ? .sent : nil
        )
    }

    private func storeTimelineItems(_ items: [TrixTimelineItem], accountJID: String, roomID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        let existingItems = timelineHistory[accountKey]?[roomKey] ?? []
        var accountHistory = timelineHistory[accountKey] ?? [:]
        let mergedItems = Array(Self.mergedTimelineItems(existingItems, items).suffix(Self.maxCachedTimelineItems))
        accountHistory[roomKey] = mergedItems
        timelineHistory[accountKey] = accountHistory
        try? timelineCacheStore.save(mergedItems, accountJID: accountJID, roomID: roomID)
    }

    @discardableResult
    private func applyReactionUpdate(_ update: CapturedReactionUpdate, accountJID: String) -> [TrixMessageReaction] {
        applyReactionUpdate(
            messageID: update.messageID,
            roomID: update.roomID,
            senderJID: update.senderJID,
            emojis: update.emojis,
            timestamp: update.timestamp,
            accountJID: accountJID
        )
    }

    @discardableResult
    private func applyReactionUpdate(
        messageID: String,
        roomID: String,
        senderJID: String,
        emojis: [String],
        timestamp: Date,
        accountJID: String
    ) -> [TrixMessageReaction] {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        guard var accountHistory = timelineHistory[accountKey],
              let existingItems = accountHistory[roomKey],
              let itemIndex = existingItems.firstIndex(where: { $0.id == messageID }) else {
            return []
        }

        var updatedItems = existingItems
        let updatedItem = Self.applyingReactionSet(
            senderJID: senderJID,
            emojis: emojis,
            timestamp: timestamp,
            accountJID: accountJID,
            to: updatedItems[itemIndex]
        )
        updatedItems[itemIndex] = updatedItem
        accountHistory[roomKey] = updatedItems
        timelineHistory[accountKey] = accountHistory
        try? timelineCacheStore.save(updatedItems, accountJID: accountJID, roomID: roomID)
        return updatedItem.reactions
    }

    @discardableResult
    private func updateTimelineDeliveryState(
        accountJID: String,
        roomID: String?,
        messageID: String,
        deliveryState: TrixDeliveryState
    ) -> Bool {
        let accountKey = accountJID.lowercased()
        guard var accountHistory = timelineHistory[accountKey] else {
            return false
        }

        let candidateRoomKeys = roomID.map { [$0.lowercased()] } ?? Array(accountHistory.keys)
        var changedRoomKeys: [String] = []
        for roomKey in candidateRoomKeys {
            guard let existingItems = accountHistory[roomKey] else {
                continue
            }

            var roomChanged = false
            let updatedItems = existingItems.map { item in
                guard item.id == messageID,
                      item.isLocalEcho,
                      item.deliveryState != deliveryState else {
                    return item
                }

                roomChanged = true
                return item.withDeliveryState(deliveryState)
            }

            guard roomChanged else {
                continue
            }

            accountHistory[roomKey] = updatedItems
            changedRoomKeys.append(roomKey)
            try? timelineCacheStore.save(updatedItems, accountJID: accountJID, roomID: roomKey)
        }

        guard !changedRoomKeys.isEmpty else {
            return false
        }

        timelineHistory[accountKey] = accountHistory
        return true
    }

    private func updateTypingRecord(
        accountJID: String,
        roomID: String,
        senderJID: String,
        state: TrixTypingState
    ) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        let senderKey = senderJID.lowercased()
        var accountRecords = typingRecords[accountKey] ?? [:]
        var roomRecords = accountRecords[roomKey] ?? [:]

        switch state {
        case .idle, .paused:
            roomRecords.removeValue(forKey: senderKey)
        case .composing:
            roomRecords[senderKey] = TypingRecord(
                userID: senderJID,
                state: state,
                updatedAt: Date()
            )
        }

        if roomRecords.isEmpty {
            accountRecords.removeValue(forKey: roomKey)
        } else {
            accountRecords[roomKey] = roomRecords
        }

        if accountRecords.isEmpty {
            typingRecords.removeValue(forKey: accountKey)
        } else {
            typingRecords[accountKey] = accountRecords
        }
    }

    private func pruneTypingRecords(accountJID: String, roomID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        guard var accountRecords = typingRecords[accountKey],
              var roomRecords = accountRecords[roomKey] else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Self.typingRecordLifetime)
        roomRecords = roomRecords.filter { _, record in
            record.updatedAt >= cutoff
        }

        if roomRecords.isEmpty {
            accountRecords.removeValue(forKey: roomKey)
        } else {
            accountRecords[roomKey] = roomRecords
        }

        if accountRecords.isEmpty {
            typingRecords.removeValue(forKey: accountKey)
        } else {
            typingRecords[accountKey] = accountRecords
        }
    }

    private func timelineItems(accountJID: String, roomID: String) -> [TrixTimelineItem] {
        timelineHistory[accountJID.lowercased()]?[roomID.lowercased()] ?? []
    }

    private func callDescriptorItems(accountJID: String, roomID: String) -> [TrixReceivedCallDescriptor] {
        callDescriptorHistory[accountJID.lowercased()]?[roomID.lowercased()] ?? []
    }

    private func storeCallDescriptors(
        _ descriptors: [TrixReceivedCallDescriptor],
        accountJID: String,
        roomID: String
    ) {
        guard !descriptors.isEmpty else {
            return
        }

        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        let existingDescriptors = callDescriptorHistory[accountKey]?[roomKey] ?? []
        var accountDescriptors = callDescriptorHistory[accountKey] ?? [:]
        let mergedDescriptors = Array(Self.mergedCallDescriptors(existingDescriptors, descriptors).suffix(Self.maxCachedCallDescriptors))
        accountDescriptors[roomKey] = mergedDescriptors
        callDescriptorHistory[accountKey] = accountDescriptors
    }

    @discardableResult
    private func loadCachedTimelineItems(accountJID: String, roomID: String) -> Int {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        guard timelineHistory[accountKey]?[roomKey] == nil,
              let cachedItems = try? timelineCacheStore.load(accountJID: accountJID, roomID: roomID),
              !cachedItems.isEmpty else {
            return 0
        }

        var accountHistory = timelineHistory[accountKey] ?? [:]
        accountHistory[roomKey] = cachedItems
        timelineHistory[accountKey] = accountHistory
        return cachedItems.count
    }

    private func storeTimelineDiagnostics(_ diagnostics: XMPPTimelineDiagnostics, accountJID: String, roomID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        var accountDiagnostics = timelineDiagnostics[accountKey] ?? [:]
        accountDiagnostics[roomKey] = diagnostics
        timelineDiagnostics[accountKey] = accountDiagnostics
    }

    private func encodeOMEMOMessage(_ message: Message, peerJID: String, connection: Connection) async throws -> Message {
        return try await encodeOMEMOMessage(message, recipientJIDs: [peerJID], connection: connection)
    }

    private func encodeOMEMOMessage(_ message: Message, recipientJIDs: [String], connection: Connection) async throws -> Message {
        await ensureOwnOMEMOSession(connection: connection)
        let accountJID = connection.client.connectionConfiguration.userJid.stringValue
        let recipients = Self.uniqueRecipientJIDs(recipientJIDs + [accountJID]).map(BareJID.init)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Message, Error>) in
            connection.omemoStack.module.encode(message: message, for: recipients) { result in
                switch result {
                case .successMessage(let encryptedMessage, _):
                    continuation.resume(returning: encryptedMessage)
                case .failure:
                    continuation.resume(throwing: TrixClientError.omemoEncryptionFailed)
                }
            }
        }
    }

    private func sendCallDescriptor(
        _ descriptor: TrixCallDescriptor,
        roomID: String,
        session: TrixSession
    ) async throws -> TrixReceivedCallDescriptor {
        let connection = try await ensureConnection(for: session)
        let normalizedRoomID = try Self.normalizedRoomID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let body = try Self.encodedCallDescriptor(descriptor)

        if Self.isMUCJID(normalizedRoomID) {
            return try await sendGroupCallDescriptor(
                descriptor,
                body: body,
                roomID: normalizedRoomID,
                accountJID: accountJID,
                session: session,
                connection: connection
            )
        }

        guard connection.omemoStack.store.hasTrustedActiveDevice(forName: normalizedRoomID) else {
            _ = try? await refreshPeerDeviceIdentities(userID: normalizedRoomID, session: session)
            guard connection.omemoStack.store.hasTrustedActiveDevice(forName: normalizedRoomID) else {
                throw TrixClientError.omemoDeviceTrustRequired
            }
            return try await sendCallDescriptor(descriptor, roomID: normalizedRoomID, session: session)
        }

        let messageID = "trix-call-\(descriptor.event.rawValue)-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .chat
        message.to = JID(normalizedRoomID)
        message.body = body
        message.messageDelivery = .request

        let encryptedMessage = try await encodeOMEMOMessage(message, peerJID: normalizedRoomID, connection: connection)
        encryptedMessage.messageDelivery = .request
        try Self.requireEncryptedOMEMOPayload(encryptedMessage)
        try await connection.omemoStack.module.write(stanza: encryptedMessage)

        let received = TrixReceivedCallDescriptor(
            id: messageID,
            roomID: normalizedRoomID,
            senderID: accountJID,
            timestamp: Date(),
            descriptor: descriptor,
            isLocalEcho: true
        )
        storeCallDescriptors([received], accountJID: accountJID, roomID: normalizedRoomID)
        return received
    }

    private func sendGroupCallDescriptor(
        _ descriptor: TrixCallDescriptor,
        body: String,
        roomID: String,
        accountJID: String,
        session: TrixSession,
        connection: Connection
    ) async throws -> TrixReceivedCallDescriptor {
        let room = try await joinedGroupRoom(roomID: roomID, session: session, connection: connection)
        let recipients = try await validatedGroupEncryptionRecipients(
            room: room,
            accountJID: accountJID,
            session: session,
            connection: connection
        )

        let messageID = "trix-call-\(descriptor.event.rawValue)-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .groupchat
        message.to = JID(roomID)
        message.body = body

        let encryptedMessage = try await encodeOMEMOMessage(message, recipientJIDs: recipients, connection: connection)
        try Self.requireEncryptedOMEMOPayload(encryptedMessage)
        try await connection.mucModule.write(stanza: encryptedMessage)

        let received = TrixReceivedCallDescriptor(
            id: messageID,
            roomID: roomID,
            senderID: accountJID,
            timestamp: Date(),
            descriptor: descriptor,
            isLocalEcho: true
        )
        storeCallDescriptors([received], accountJID: accountJID, roomID: roomID)
        updateGroupActivity(roomID: roomID, accountJID: accountJID, at: received.timestamp)
        return received
    }

    private func sendGroupText(
        _ body: String,
        roomID: String,
        session: TrixSession,
        connection: Connection
    ) async throws -> TrixTimelineItem {
        let room = try await joinedGroupRoom(roomID: roomID, session: session, connection: connection)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let recipients = try await validatedGroupEncryptionRecipients(
            room: room,
            accountJID: accountJID,
            session: session,
            connection: connection
        )

        let messageID = "trix-group-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .groupchat
        message.to = JID(roomID)
        message.body = body

        let encryptedMessage = try await encodeOMEMOMessage(message, recipientJIDs: recipients, connection: connection)
        guard encryptedMessage.body == nil,
              let encrypted = encryptedMessage.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS),
              let header = encrypted.firstChild(name: "header"),
              !header.filterChildren(name: "key", xmlns: nil).isEmpty else {
            throw TrixClientError.omemoEncryptionFailed
        }

        try await connection.mucModule.write(stanza: encryptedMessage)

        let item = TrixTimelineItem(
            id: messageID,
            roomID: roomID,
            sender: accountJID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true,
            attachment: nil,
            deliveryState: .sent
        )
        storeTimelineItems([item], accountJID: accountJID, roomID: roomID)
        updateGroupActivity(roomID: roomID, accountJID: accountJID, at: item.timestamp)
        return item
    }

    private func sendGroupAttachment(
        _ attachment: TrixAttachmentUpload,
        roomID: String,
        session: TrixSession,
        connection: Connection
    ) async throws -> TrixTimelineItem {
        let room = try await joinedGroupRoom(roomID: roomID, session: session, connection: connection)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let recipients = try await validatedGroupEncryptionRecipients(
            room: room,
            accountJID: accountJID,
            session: session,
            connection: connection
        )

        let encryptedMedia: (data: Data, fragment: String)
        switch connection.omemoStack.module.encryptFile(data: attachment.data) {
        case .success(let result):
            encryptedMedia = (data: result.0, fragment: result.1)
        case .failure:
            throw TrixClientError.attachmentEncryptionUnavailable
        }

        let uploadModule: HttpFileUploadModule = connection.client.modulesManager.module(.httpFileUpload)
        let uploadComponent = try await uploadModule.findHttpUploadComponents()
            .filter { $0.maxSize >= encryptedMedia.data.count }
            .sorted { $0.maxSize < $1.maxSize }
            .first
        guard let uploadComponent else {
            throw TrixClientError.attachmentTransferFailed
        }

        let encryptedFilename = "trix-\(UUID().uuidString).enc"
        let slot = try await uploadModule.requestUploadSlot(
            componentJid: uploadComponent.jid,
            filename: encryptedFilename,
            size: encryptedMedia.data.count,
            contentType: "application/octet-stream"
        )
        try await uploadEncryptedAttachment(encryptedMedia.data, slot: slot)

        let descriptor = EncryptedAttachmentDescriptor(
            type: Self.encryptedAttachmentDescriptorType,
            version: 1,
            downloadURL: slot.getUri.absoluteString,
            fragment: encryptedMedia.fragment,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            originalSizeBytes: attachment.data.count,
            encryptedSizeBytes: encryptedMedia.data.count,
            imageDimensions: attachment.imageDimensions,
            imageBlurhash: attachment.imageBlurhash,
            stickerMetadata: attachment.stickerMetadata
        )
        let descriptorJSON = try Self.encodedAttachmentDescriptor(descriptor)

        let messageID = "trix-group-attachment-\(UUID().uuidString)"
        let message = Message()
        message.id = messageID
        message.type = .groupchat
        message.to = JID(roomID)
        message.body = descriptorJSON

        let encryptedMessage = try await encodeOMEMOMessage(message, recipientJIDs: recipients, connection: connection)
        guard encryptedMessage.body == nil,
              let encrypted = encryptedMessage.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS),
              let header = encrypted.firstChild(name: "header"),
              !header.filterChildren(name: "key", xmlns: nil).isEmpty else {
            throw TrixClientError.omemoEncryptionFailed
        }

        try await connection.mucModule.write(stanza: encryptedMessage)

        let item = TrixTimelineItem(
            id: messageID,
            roomID: roomID,
            sender: accountJID,
            timestamp: Date(),
            body: Self.attachmentTimelineBody(for: attachment),
            isLocalEcho: true,
            attachment: Self.timelineAttachment(from: descriptor, sourceJSON: descriptorJSON),
            deliveryState: .sent
        )
        storeTimelineItems([item], accountJID: accountJID, roomID: roomID)
        updateGroupActivity(roomID: roomID, accountJID: accountJID, at: item.timestamp)
        return item
    }

    private func joinedGroupRoom(roomID: String, session: TrixSession, connection: Connection) async throws -> RoomProtocol {
        if let room = connection.mucModule.roomManager.room(for: connection.client, with: BareJID(roomID)),
           room.state == .joined {
            let accountJID = try Self.normalizedXMPPJID(session.userID)
            cacheGroupMembers(Self.memberUserIDs(from: room, fallbackAccountJID: accountJID), roomID: roomID, accountJID: accountJID, name: nil)
            return room
        }

        let summary = try await joinGroupRoom(roomID: roomID, displayName: nil, password: nil, session: session, connection: connection)
        guard let room = connection.mucModule.roomManager.room(for: connection.client, with: BareJID(summary.id)) else {
            throw TrixClientError.roomUnavailable
        }
        return room
    }

    private func joinGroupRoom(
        roomID: String,
        displayName: String?,
        password: String?,
        session: TrixSession,
        connection: Connection
    ) async throws -> TrixRoomSummary {
        let mucJID = try Self.normalizedMUCJID(roomID)
        let accountJID = try Self.normalizedXMPPJID(session.userID)
        let room = try await joinMucRoom(roomID: mucJID, password: password, accountJID: accountJID, connection: connection)
        let name = displayName ?? cachedGroup(roomID: mucJID, accountJID: accountJID)?.name ?? Self.displayName(from: mucJID)
        cacheGroupMembers(Self.memberUserIDs(from: room, fallbackAccountJID: accountJID), roomID: mucJID, accountJID: accountJID, name: name)
        try? await bookmarkGroupRoom(roomID: mucJID, name: name, nickname: Self.mucNickname(from: accountJID), connection: connection)
        return TrixRoomSummary(
            id: mucJID,
            name: name,
            kind: .group,
            isEncrypted: true,
            unreadCount: 0,
            lastMessagePreview: "Trust OMEMO devices for every member before sending",
            lastActivityAt: Date()
        )
    }

    private func joinMucRoom(
        roomID: String,
        password: String?,
        accountJID: String,
        connection: Connection
    ) async throws -> RoomProtocol {
        let bareJID = BareJID(roomID)
        if let existingRoom = connection.mucModule.roomManager.room(for: connection.client, with: bareJID) {
            if existingRoom.state == .joined {
                return existingRoom
            }

            connection.mucModule.roomManager.close(room: existingRoom)
        }

        guard let room = connection.mucModule.roomManager.createRoom(
            for: connection.client,
            with: bareJID,
            nickname: Self.mucNickname(from: accountJID),
            password: password
        ) else {
            throw TrixClientError.roomUnavailable
        }

        let result = try await joinMucRoom(room, connection: connection)
        return Self.room(from: result)
    }

    private func joinMucRoom(_ room: RoomProtocol, connection: Connection) async throws -> RoomJoinResult {
        try await withCheckedThrowingContinuation { continuation in
            let waitState = XMPPMUCJoinWaitState(
                continuation: continuation,
                mucModule: connection.mucModule,
                room: room
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mucJoinTimeout) {
                waitState.resumeThrowing(TrixClientError.roomJoinTimedOut, leaveRoom: true)
            }
            connection.mucModule.join(room: room, fetchHistory: .initial) { result in
                waitState.resume(with: result)
            }
        }
    }

    private func configurePrivateGroupRoom(
        room: RoomProtocol,
        name: String,
        inviteeUserIDs: [String],
        ownerJID: String,
        connection: Connection
    ) async throws {
        let config = try await roomConfiguration(roomJID: JID(room.jid), connection: connection)
        config.name = name
        config.desc = "Trix private OMEMO group"
        config.membersOnly = true
        config.publicRoom = false
        config.persistentRoom = true
        config.allowInvites = true
        config.passwordProtectedRoom = false
        config.whois = .anyone
        try await setRoomConfiguration(config, roomJID: JID(room.jid), connection: connection)

        let affiliations = [MucModule.RoomAffiliation(jid: JID(ownerJID), affiliation: .owner)]
            + inviteeUserIDs.map { MucModule.RoomAffiliation(jid: JID($0), affiliation: .admin) }
        try await setGroupAffiliations(affiliations, room: room, connection: connection)
    }

    private func validatedGroupEncryptionRecipients(
        room: RoomProtocol,
        accountJID: String,
        session: TrixSession,
        connection: Connection
    ) async throws -> [String] {
        let roomID = room.jid.stringValue
        let accountKey = accountJID.lowercased()
        var members = Set<String>()

        do {
            for affiliation in [MucAffiliation.owner, .admin, .member] {
                let affiliations = try await roomAffiliations(room: room, affiliation: affiliation, connection: connection)
                members.formUnion(affiliations.map { $0.userID.lowercased() })
            }
        } catch {
            throw TrixClientError.groupOmemoRecipientSetUnavailable
        }

        members.formUnion(Self.memberUserIDs(from: room, fallbackAccountJID: accountJID))
        cacheGroupMembers(members, roomID: roomID, accountJID: accountJID, name: nil)

        let recipients = members
            .filter { $0.lowercased() != accountKey }
            .sorted()
        guard !recipients.isEmpty else {
            throw TrixClientError.groupOmemoRecipientSetUnavailable
        }

        for recipient in recipients where !connection.omemoStack.store.hasTrustedActiveDevice(forName: recipient) {
            _ = try? await refreshPeerDeviceIdentities(userID: recipient, session: session)
        }
        guard recipients.allSatisfy({ connection.omemoStack.store.hasTrustedActiveDevice(forName: $0) }) else {
            throw TrixClientError.groupOmemoDeviceTrustRequired
        }

        return recipients
    }

    private func groupMembers(room: RoomProtocol, accountJID: String, connection: Connection) async throws -> [TrixRoomMember] {
        var membersByID: [String: TrixRoomMember] = [:]
        let roomID = room.jid.stringValue
        if let cached = cachedGroup(roomID: roomID, accountJID: accountJID) {
            for jid in cached.memberUserIDs {
                membersByID[jid.lowercased()] = TrixRoomMember(
                    userID: jid,
                    displayName: Self.displayName(from: jid),
                    membership: .joined
                )
            }
        }

        for occupant in Self.occupants(from: room) {
            guard let jid = occupant.jid?.bareJid.stringValue else {
                continue
            }
            membersByID[jid.lowercased()] = TrixRoomMember(
                userID: jid,
                displayName: Self.displayName(from: jid),
                membership: .joined
            )
        }

        for affiliation in [MucAffiliation.owner, .admin, .member] {
            let affiliations = (try? await roomAffiliations(room: room, affiliation: affiliation, connection: connection)) ?? []
            for item in affiliations {
                let jid = item.userID
                membersByID[jid.lowercased()] = TrixRoomMember(
                    userID: jid,
                    displayName: item.nickname ?? Self.displayName(from: jid),
                    membership: .joined
                )
            }
        }

        if membersByID[accountJID.lowercased()] == nil {
            membersByID[accountJID.lowercased()] = TrixRoomMember(
                userID: accountJID,
                displayName: Self.displayName(from: accountJID),
                membership: .joined
            )
        }

        return membersByID.values.sorted { lhs, rhs in
            if lhs.membership.sortOrder != rhs.membership.sortOrder {
                return lhs.membership.sortOrder < rhs.membership.sortOrder
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func roomConfiguration(roomJID: JID, connection: Connection) async throws -> RoomConfig {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RoomConfig, Error>) in
            connection.mucModule.roomConfiguration(roomJid: roomJID) { result in
                switch result {
                case .success(let config):
                    continuation.resume(returning: config)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setRoomConfiguration(_ config: RoomConfig, roomJID: JID, connection: Connection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.mucModule.setRoomConfiguration(roomJid: roomJID, configuration: config) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func roomAffiliations(
        room: RoomProtocol,
        affiliation: MucAffiliation,
        connection: Connection
    ) async throws -> [GroupAffiliationRecord] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[GroupAffiliationRecord], Error>) in
            connection.mucModule.getRoomAffiliations(from: room, with: affiliation) { result in
                switch result {
                case .success(let affiliations):
                    let records = affiliations.map { item in
                        GroupAffiliationRecord(
                            userID: item.jid.bareJid.stringValue,
                            nickname: item.nickname
                        )
                    }
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func setGroupAffiliations(
        _ affiliations: [MucModule.RoomAffiliation],
        room: RoomProtocol,
        connection: Connection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.mucModule.setRoomAffiliations(to: room, changedAffiliations: affiliations) { result in
                switch result {
                case .success:
                    continuation.resume(returning: ())
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func bookmarkGroupRoom(roomID: String, name: String, nickname: String, connection: Connection) async throws {
        let bookmark = Bookmarks.Conference(
            name: name,
            jid: JID(roomID),
            autojoin: true,
            nick: nickname,
            password: nil
        )
        try await connection.bookmarksModule.addOrUpdate(bookmark: bookmark)
    }

    private func createNotificationProfilesNode(connection: Connection, accountJID: String) async throws {
        let config = PubSubNodeConfig()
        config.FORM_TYPE = "http://jabber.org/protocol/pubsub#node_config"
        config.persistItems = true
        config.accessModel = .whitelist
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.pubSubModule.createNode(
                at: BareJID(accountJID),
                node: Self.notificationProfilesNode,
                with: config
            ) { result in
                continuation.resume(with: result.map { _ in () })
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

    private func uploadEncryptedAttachment(_ data: Data, slot: HttpFileUploadModule.Slot) async throws {
        var request = URLRequest(url: slot.putUri)
        request.httpMethod = "PUT"
        for (name, value) in slot.putHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }

        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw TrixClientError.attachmentTransferFailed
        }
    }

    private func downloadEncryptedAttachment(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw TrixClientError.attachmentTransferFailed
        }

        return data
    }

    private func ensureDirectRosterItem(peerJID: String, displayName: String, connection: Connection) async throws {
        guard peerJID.caseInsensitiveCompare(connection.client.connectionConfiguration.userJid.stringValue) != .orderedSame else {
            throw TrixClientError.invalidTrixUserID
        }

        let jid = JID(peerJID)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? Self.displayName(from: peerJID) : trimmedName
        _ = try await connection.rosterModule.addItem(jid: jid, name: finalName, groups: ["Trix"])
        try await connection.rosterModule.requestRoster()
    }

    private func cacheGroupMembers(_ memberUserIDs: [String], roomID: String, accountJID: String, name: String?) {
        cacheGroupMembers(Set(memberUserIDs), roomID: roomID, accountJID: accountJID, name: name)
    }

    private func cacheGroupMembers(_ memberUserIDs: Set<String>, roomID: String, accountJID: String, name: String?) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        var groups = knownGroupRooms[accountKey] ?? [:]
        let existing = groups[roomKey] ?? loadCachedGroup(roomID: roomID, accountJID: accountJID)
        var mergedMembers = existing?.memberUserIDs ?? []
        mergedMembers.formUnion(memberUserIDs.map { $0.lowercased() })
        let group = KnownGroupRoom(
            roomID: roomID,
            name: name ?? existing?.name ?? Self.displayName(from: roomID),
            memberUserIDs: mergedMembers,
            lastActivityAt: existing?.lastActivityAt ?? Date()
        )
        groups[roomKey] = group
        knownGroupRooms[accountKey] = groups
        saveCachedGroup(group, accountJID: accountJID)
    }

    private func removeCachedGroupMember(_ userID: String, roomID: String, accountJID: String) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        var groups = knownGroupRooms[accountKey] ?? [:]
        guard var group = groups[roomKey] ?? loadCachedGroup(roomID: roomID, accountJID: accountJID) else {
            return
        }

        group.memberUserIDs.remove(userID.lowercased())
        groups[roomKey] = group
        knownGroupRooms[accountKey] = groups
        saveCachedGroup(group, accountJID: accountJID)
    }

    private func cachedGroup(roomID: String, accountJID: String) -> KnownGroupRoom? {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        if let group = knownGroupRooms[accountKey]?[roomKey] {
            return group
        }
        guard let group = loadCachedGroup(roomID: roomID, accountJID: accountJID) else {
            return nil
        }

        var groups = knownGroupRooms[accountKey] ?? [:]
        groups[roomKey] = group
        knownGroupRooms[accountKey] = groups
        return group
    }

    private func updateGroupActivity(roomID: String, accountJID: String, at date: Date) {
        let accountKey = accountJID.lowercased()
        let roomKey = roomID.lowercased()
        var groups = knownGroupRooms[accountKey] ?? [:]
        var group = groups[roomKey] ?? loadCachedGroup(roomID: roomID, accountJID: accountJID) ?? KnownGroupRoom(
            roomID: roomID,
            name: Self.displayName(from: roomID),
            memberUserIDs: [accountJID.lowercased()],
            lastActivityAt: date
        )

        group.lastActivityAt = date
        groups[roomKey] = group
        knownGroupRooms[accountKey] = groups
        saveCachedGroup(group, accountJID: accountJID)
    }

    private func loadCachedGroup(roomID: String, accountJID: String) -> KnownGroupRoom? {
        guard let cached = try? groupRoomCacheStore.load(accountJID: accountJID, roomID: roomID) else {
            return nil
        }
        return KnownGroupRoom(cached: cached)
    }

    private func saveCachedGroup(_ group: KnownGroupRoom, accountJID: String) {
        try? groupRoomCacheStore.save(group.cached, accountJID: accountJID)
    }

    private func publishDirectoryProfileIfNeeded(session: TrixSession, connection: Connection) async throws {
        let jid = try Self.normalizedXMPPJID(session.userID)
        let currentVCard = try? await retrieveVCardElement(for: jid, connection: connection)
        let update = Self.directoryDefaultVCard(currentVCard, userID: jid)
        guard update.changed else {
            return
        }

        try await publishVCardElement(update.vCard, connection: connection)
    }

    private func retrieveVCardElement(for userID: String, connection: Connection) async throws -> Element? {
        let iq = Iq()
        iq.type = .get
        iq.to = JID(userID)
        iq.addChild(Element(name: "vCard", xmlns: "vcard-temp"))

        let response = try await connection.vCardModule.write(iq: iq, timeout: 10)
        return response.firstChild(name: "vCard", xmlns: "vcard-temp")
    }

    private func publishVCardElement(_ vCard: Element, connection: Connection) async throws {
        let iq = Iq()
        iq.type = .set
        iq.addChild(vCard)
        _ = try await connection.vCardModule.write(iq: iq, timeout: 10)
    }

    private func searchDirectoryUsers(
        _ searchTerm: String,
        limit: Int,
        connection: Connection
    ) async throws -> [TrixUserProfile] {
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

        var users: [TrixUserProfile] = []
        for field in ["user", "nick", "fn", "first", "last", "email"] {
            let response = try? await directorySearchResponse(fields: [field: needle], connection: connection)
            if let response {
                users.append(contentsOf: Self.directoryUsers(from: response))
            }
        }

        return Self.deduplicatedUsers(users)
    }

    private func pushGatewayJID(connection: Connection) async throws -> JID {
        do {
            let components = try await connection.pushModule.findPushComponents(requiredFeatures: [])
            guard let component = components.first else {
                throw TrixClientError.apnsGatewayUnavailable
            }
            return component
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.apnsGatewayUnavailable
        }
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
        let omemoStack = try TrixOMEMOStore.makeStack(account: jid, persistence: omemoPersistence)
        let client = XMPPClient()
        client.connectionConfiguration.userJid = BareJID(jid)
        client.connectionConfiguration.credentials = .password(password: password)
        client.connectionConfiguration.resource = resource
        client.connectionConfiguration.disableTLS = false
        client.connectionConfiguration.disableCompression = true
        client.connectionConfiguration.modifyConnectorOptions(type: SocketConnector.Options.self) { options in
            options.conntectionTimeout = Self.xmppConnectionTimeout
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
        _ = client.modulesManager.register(AdHocCommandsModule())
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
        let csiModule = ClientStateIndicationModule()
        _ = client.modulesManager.register(csiModule)
        let mamModule = MessageArchiveManagementModule()
        _ = client.modulesManager.register(mamModule)
        let deliveryReceiptsModule = MessageDeliveryReceiptsModule()
        deliveryReceiptsModule.sendReceived = true
        _ = client.modulesManager.register(deliveryReceiptsModule)
        // ChatStateNotificationsModule reads the capabilities module when its context is set.
        _ = client.modulesManager.register(CapabilitiesModule())
        let chatStateModule = ChatStateNotificationsModule()
        _ = client.modulesManager.register(chatStateModule)
        _ = client.modulesManager.register(HttpFileUploadModule())
        let pubSubModule = PubSubModule()
        _ = client.modulesManager.register(pubSubModule)
        let bookmarksModule = PEPBookmarksModule()
        _ = client.modulesManager.register(bookmarksModule)
        let pushModule = TigasePushNotificationsModule()
        _ = client.modulesManager.register(pushModule)
        let mucModule = MucModule(roomManager: RoomManagerBase(store: TrixMucRoomStore()))
        _ = client.modulesManager.register(mucModule)
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
            deliveryReceiptsModule: deliveryReceiptsModule,
            chatStateModule: chatStateModule,
            csiModule: csiModule,
            mucModule: mucModule,
            bookmarksModule: bookmarksModule,
            pubSubModule: pubSubModule,
            pushModule: pushModule,
            omemoStack: omemoStack
        )
    }

    private static func decodedTimelineContent(from body: String) -> DecodedTimelineContent {
        guard let descriptor = decodedAttachmentDescriptor(from: body) else {
            return DecodedTimelineContent(body: body, attachment: nil)
        }

        return DecodedTimelineContent(
            body: attachmentTimelineBody(for: descriptor),
            attachment: timelineAttachment(from: descriptor, sourceJSON: body)
        )
    }

    private static func timelineAttachment(
        from descriptor: EncryptedAttachmentDescriptor,
        sourceJSON: String
    ) -> TrixTimelineAttachment {
        TrixTimelineAttachment(
            kind: descriptor.stickerMetadata != nil ? .sticker : (descriptor.mimeType?.hasPrefix("image/") == true ? .image : .file),
            filename: descriptor.filename,
            mimeType: descriptor.mimeType,
            sizeBytes: descriptor.originalSizeBytes,
            sourceJSON: sourceJSON,
            imageDimensions: descriptor.imageDimensions,
            imageBlurhash: descriptor.imageBlurhash,
            stickerMetadata: descriptor.stickerMetadata
        )
    }

    private static func attachmentTimelineBody(for attachment: TrixAttachmentUpload) -> String {
        guard let stickerMetadata = attachment.stickerMetadata else {
            return "Attachment: \(attachment.filename)"
        }

        return stickerTimelineBody(emoji: stickerMetadata.emoji, packTitle: stickerMetadata.packTitle)
    }

    private static func attachmentTimelineBody(for descriptor: EncryptedAttachmentDescriptor) -> String {
        guard let stickerMetadata = descriptor.stickerMetadata else {
            return "Attachment: \(descriptor.filename)"
        }

        return stickerTimelineBody(emoji: stickerMetadata.emoji, packTitle: stickerMetadata.packTitle)
    }

    private static func stickerTimelineBody(emoji: String?, packTitle: String) -> String {
        if let emoji, !emoji.isEmpty {
            return "Sticker \(emoji)"
        }

        return "Sticker: \(packTitle)"
    }

    private static func encodedAttachmentDescriptor(_ descriptor: EncryptedAttachmentDescriptor) throws -> String {
        let data = try JSONEncoder().encode(descriptor)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TrixClientError.attachmentTransferFailed
        }

        return json
    }

    private static func encodedCallDescriptor(_ descriptor: TrixCallDescriptor) throws -> String {
        let envelope = EncryptedCallDescriptorEnvelope(
            type: callDescriptorContentType(descriptor),
            version: 1,
            payload: try callDescriptorPayload(descriptor)
        )
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TrixClientError.callDescriptorUnavailable
        }

        return json
    }

    private static func decodedCallDescriptor(from sourceJSON: String?) -> TrixCallDescriptor? {
        guard let data = sourceJSON?.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(EncryptedCallDescriptorEnvelope.self, from: data),
              envelope.version == 1,
              !envelope.payload.isEmpty else {
            return nil
        }

        switch envelope.type {
        case TrixCallInvite.contentType:
            return (try? JSONDecoder().decode(TrixCallInvite.self, from: envelope.payload)).map(TrixCallDescriptor.invite)
        case TrixCallAnswer.contentType:
            return (try? JSONDecoder().decode(TrixCallAnswer.self, from: envelope.payload)).map(TrixCallDescriptor.answer)
        case TrixCallEnd.contentType:
            return (try? JSONDecoder().decode(TrixCallEnd.self, from: envelope.payload)).map(TrixCallDescriptor.end)
        case TrixVoiceRoomState.contentType:
            return (try? JSONDecoder().decode(TrixVoiceRoomState.self, from: envelope.payload)).map(TrixCallDescriptor.voiceRoomState)
        case TrixCallKeyRotation.contentType:
            return (try? JSONDecoder().decode(TrixCallKeyRotation.self, from: envelope.payload)).map(TrixCallDescriptor.keyRotation)
        default:
            return nil
        }
    }

    private static func callDescriptorContentType(_ descriptor: TrixCallDescriptor) -> String {
        switch descriptor {
        case .invite:
            return TrixCallInvite.contentType
        case .answer:
            return TrixCallAnswer.contentType
        case .end:
            return TrixCallEnd.contentType
        case .voiceRoomState:
            return TrixVoiceRoomState.contentType
        case .keyRotation:
            return TrixCallKeyRotation.contentType
        }
    }

    private static func callDescriptorPayload(_ descriptor: TrixCallDescriptor) throws -> Data {
        switch descriptor {
        case .invite(let value):
            return try JSONEncoder().encode(value)
        case .answer(let value):
            return try JSONEncoder().encode(value)
        case .end(let value):
            return try JSONEncoder().encode(value)
        case .voiceRoomState(let value):
            return try JSONEncoder().encode(value)
        case .keyRotation(let value):
            return try JSONEncoder().encode(value)
        }
    }

    private static func decodedAttachmentDescriptor(from sourceJSON: String?) -> EncryptedAttachmentDescriptor? {
        guard let data = sourceJSON?.data(using: .utf8),
              let descriptor = try? JSONDecoder().decode(EncryptedAttachmentDescriptor.self, from: data),
              descriptor.type == encryptedAttachmentDescriptorType,
              descriptor.version == 1,
              !descriptor.downloadURL.isEmpty,
              !descriptor.fragment.isEmpty,
              !descriptor.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return descriptor
    }

    private static func normalizedReactionEmoji(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else {
            throw TrixClientError.reactionsUnavailable
        }
        return trimmed
    }

    private static func uniqueReactionEmojis(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var emojis: [String] = []
        for value in values {
            guard let emoji = try? normalizedReactionEmoji(value),
                  seen.insert(emoji).inserted else {
                continue
            }
            emojis.append(emoji)
        }
        return emojis
    }

    private static func reactionMessage(
        roomID: String,
        messageID: String,
        emojis: [String],
        isGroup: Bool
    ) -> Message {
        let message = Message()
        message.id = "trix-reaction-\(UUID().uuidString)"
        message.type = isGroup ? .groupchat : .chat
        message.to = JID(roomID)

        let reactions = Element(name: "reactions", xmlns: messageReactionsXMLNS)
        reactions.setAttribute("id", value: messageID)
        for emoji in uniqueReactionEmojis(emojis) {
            reactions.addChild(Element(name: "reaction", cdata: emoji))
        }
        message.addChild(reactions)
        message.addChild(Element(name: "store", xmlns: "urn:xmpp:hints"))
        return message
    }

    private static func capturedReactionUpdate(
        from message: Message,
        accountJID: String,
        roomID: String,
        senderJID: String?,
        carbonAction: MessageCarbonsModule.Action?,
        timestamp: Date
    ) -> CapturedReactionUpdate? {
        guard let reactions = message.firstChild(name: "reactions", xmlns: messageReactionsXMLNS),
              let targetMessageID = reactions.getAttribute("id")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !targetMessageID.isEmpty else {
            return nil
        }

        let resolvedSenderJID: String?
        if let senderJID {
            resolvedSenderJID = senderJID
        } else if case .sent? = carbonAction {
            resolvedSenderJID = accountJID
        } else if let from = message.from?.bareJid.stringValue,
                  from.lowercased() == accountJID.lowercased(),
                  let to = message.to?.bareJid.stringValue,
                  to.lowercased() == roomID.lowercased() {
            resolvedSenderJID = accountJID
        } else {
            resolvedSenderJID = message.from?.bareJid.stringValue
        }

        guard let resolvedSenderJID,
              !resolvedSenderJID.isEmpty else {
            return nil
        }

        let emojis = uniqueReactionEmojis(
            reactions
                .filterChildren(name: "reaction", xmlns: nil)
                .compactMap(\.value)
        )
        return CapturedReactionUpdate(
            messageID: targetMessageID,
            roomID: roomID,
            senderJID: resolvedSenderJID,
            emojis: emojis,
            timestamp: timestamp
        )
    }

    private static func applyingReactionUpdate(
        _ update: CapturedReactionUpdate,
        to items: [TrixTimelineItem],
        accountJID: String
    ) -> [TrixTimelineItem] {
        guard let itemIndex = items.firstIndex(where: { $0.id == update.messageID }) else {
            return items
        }

        var updatedItems = items
        updatedItems[itemIndex] = applyingReactionSet(
            senderJID: update.senderJID,
            emojis: update.emojis,
            timestamp: update.timestamp,
            accountJID: accountJID,
            to: updatedItems[itemIndex]
        )
        return updatedItems
    }

    private static func applyingReactionSet(
        senderJID: String,
        emojis: [String],
        timestamp: Date,
        accountJID: String,
        to item: TrixTimelineItem
    ) -> TrixTimelineItem {
        let senderKey = senderJID.lowercased()
        let localKey = accountJID.lowercased()
        let preservedReactions = item.reactions.filter { $0.sender.lowercased() != senderKey }
        let replacements = uniqueReactionEmojis(emojis).map { emoji in
            TrixMessageReaction(
                emoji: emoji,
                sender: senderJID,
                timestamp: timestamp,
                isLocalEcho: senderKey == localKey
            )
        }
        return item.withReactions((preservedReactions + replacements).sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            if lhs.sender != rhs.sender {
                return lhs.sender < rhs.sender
            }
            return lhs.emoji < rhs.emoji
        })
    }

    private static func capturedMUCInvitation(
        from message: Message,
        receivedAt: Date
    ) -> CapturedMUCInvitation? {
        if let x = message.findChild(name: "x", xmlns: "http://jabber.org/protocol/muc#user"),
           let invite = x.findChild(name: "invite"),
           let roomJID = message.from?.bareJid.stringValue {
            let inviterUserID = JID(invite.getAttribute("from"))?.bareJid.stringValue
            return CapturedMUCInvitation(
                roomID: roomJID,
                roomName: displayName(from: roomJID),
                inviterUserID: inviterUserID,
                password: nonEmpty(x.getAttribute("password")),
                reason: firstNonEmpty(invite.findChild(name: "reason")?.value, invite.getAttribute("reason")),
                receivedAt: receivedAt,
                transport: .mediated
            )
        }

        if let x = message.findChild(name: "x", xmlns: "jabber:x:conference"),
           let roomJID = x.getAttribute("jid") {
            return CapturedMUCInvitation(
                roomID: roomJID,
                roomName: displayName(from: roomJID),
                inviterUserID: message.from?.bareJid.stringValue,
                password: nonEmpty(x.getAttribute("password")),
                reason: nonEmpty(x.getAttribute("reason")),
                receivedAt: receivedAt,
                transport: .direct
            )
        }

        return nil
    }

    private static func mucInvitationTransport(from invitation: MucModule.Invitation) -> MUCInvitationTransport {
        if invitation is MucModule.MediatedInvitation {
            return .mediated
        }
        if invitation is MucModule.DirectInvitation {
            return .direct
        }
        return .unknown
    }

    private static func normalizedCapturedMUCInvitation(
        _ invitation: CapturedMUCInvitation
    ) -> CapturedMUCInvitation? {
        guard let roomID = try? normalizedMUCJID(invitation.roomID) else {
            return nil
        }

        let inviterUserID = invitation.inviterUserID.flatMap { try? normalizedXMPPJID($0) }
        return CapturedMUCInvitation(
            roomID: roomID,
            roomName: nonEmpty(invitation.roomName) ?? displayName(from: roomID),
            inviterUserID: inviterUserID,
            password: nonEmpty(invitation.password),
            reason: nonEmpty(invitation.reason),
            receivedAt: invitation.receivedAt,
            transport: invitation.transport
        )
    }

    private static func normalizedXMPPJID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw TrixClientError.invalidTrixUserID
        }

        if trimmed.hasPrefix("@"), let separator = trimmed.firstIndex(of: ":") {
            let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
            let server = String(trimmed[trimmed.index(after: separator)...])
            guard !localpart.isEmpty, server == XMPPClientConfiguration.serverName else {
                throw TrixClientError.invalidTrixUserID
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
            throw TrixClientError.invalidTrixUserID
        }

        return trimmed
    }

    private static func normalizedMUCJID(_ roomID: String) throws -> String {
        let trimmed = roomID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let jid = BareJID(trimmed)
        guard let localpart = jid.localPart,
              !localpart.isEmpty,
              jid.domain == XMPPClientConfiguration.conferenceServerName,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TrixClientError.roomUnavailable
        }
        return jid.stringValue
    }

    private static func normalizedRoomID(_ roomID: String) throws -> String {
        if let mucJID = try? normalizedMUCJID(roomID) {
            return mucJID
        }
        return try normalizedXMPPJID(roomID)
    }

    private static func notificationProfileElement(
        from snapshot: TrixRoomNotificationProfileSnapshot
    ) -> Element {
        let element = Element(name: "profiles", xmlns: notificationProfilesNode)
        element.setAttribute("version", value: "1")
        element.setAttribute("updated-at", value: ISO8601DateFormatter().string(from: snapshot.updatedAt))

        for (roomID, profile) in snapshot.profilesByRoomID.sorted(by: { $0.key < $1.key }) {
            let roomElement = Element(name: "room")
            roomElement.setAttribute("id", value: roomID)
            roomElement.setAttribute("profile", value: profile.rawValue)
            element.addChild(roomElement)
        }

        return element
    }

    private static func notificationProfileSnapshot(
        from element: Element
    ) -> TrixRoomNotificationProfileSnapshot? {
        guard element.name == "profiles",
              element.xmlns == notificationProfilesNode else {
            return nil
        }

        var profilesByRoomID: [String: TrixRoomNotificationProfile] = [:]
        element.forEachChild { child in
            guard child.name == "room",
                  let roomID = child.getAttribute("id"),
                  let rawProfile = child.getAttribute("profile"),
                  let profile = TrixRoomNotificationProfile(rawValue: rawProfile) else {
                return
            }

            let normalizedRoomID = TrixRoomNotificationProfileSnapshot.normalizedRoomID(roomID)
            guard !normalizedRoomID.isEmpty, profile != .defaultProfile else {
                return
            }
            profilesByRoomID[normalizedRoomID] = profile
        }

        let updatedAt = element
            .getAttribute("updated-at")
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        return TrixRoomNotificationProfileSnapshot(
            profilesByRoomID: profilesByRoomID,
            updatedAt: updatedAt
        )
    }

    private static func isMUCJID(_ roomID: String) -> Bool {
        BareJID(roomID).domain == XMPPClientConfiguration.conferenceServerName
    }

    private static func normalizedGroupInvitees(_ inviteeUserIDs: [String], excluding currentUserID: String) throws -> [String] {
        let current = try normalizedXMPPJID(currentUserID).lowercased()
        var seen = Set<String>()
        var invitees: [String] = []
        for inviteeUserID in inviteeUserIDs {
            let normalized = try normalizedXMPPJID(inviteeUserID)
            let key = normalized.lowercased()
            guard key != current, seen.insert(key).inserted else {
                continue
            }
            invitees.append(normalized)
        }
        return invitees
    }

    private static func uniqueRecipientJIDs(_ recipientJIDs: [String]) -> [String] {
        var seen = Set<String>()
        var recipients: [String] = []
        for recipientJID in recipientJIDs {
            let normalized = recipientJID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty,
                  seen.insert(normalized).inserted else {
                continue
            }

            recipients.append(normalized)
        }
        return recipients
    }

    private static func groupRoomLocalpart(from name: String) -> String {
        let folded = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let allowed = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(allowed)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = slug.isEmpty ? "group" : slug
        return "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func mucNickname(from userID: String) -> String {
        let localpart = BareJID(userID).localPart ?? displayName(from: userID)
        let filtered = localpart.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let nick = String(filtered)
            .split(separator: "-")
            .joined(separator: "-")
        return nick.isEmpty ? "trix" : nick
    }

    private static func room(from result: RoomJoinResult) -> RoomProtocol {
        switch result {
        case .created(let room), .joined(let room):
            return room
        }
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

    private static func deliveryReceiptRoomID(from message: Message, accountJID: String) -> String? {
        roomID(for: message, accountJID: accountJID, carbonAction: nil)
    }

    private static func occupants(from room: RoomProtocol) -> [MucOccupant] {
        (room as? RoomBase)?.occupants ?? []
    }

    private static func memberUserIDs(from room: RoomProtocol, fallbackAccountJID: String) -> Set<String> {
        var members = Set<String>()
        for occupant in occupants(from: room) {
            if let jid = occupant.jid?.bareJid.stringValue {
                members.insert(jid.lowercased())
            }
        }
        members.insert(fallbackAccountJID.lowercased())
        return members
    }

    private static func groupMessageSenderJID(_ message: Message, room: RoomProtocol, accountJID: String) -> String? {
        guard let nickname = message.from?.resource else {
            return nil
        }
        if nickname == room.nickname {
            return accountJID
        }
        return room.occupant(nickname: nickname)?.jid?.bareJid.stringValue
    }

    private static func typingState(from chatState: ChatState) -> TrixTypingState {
        switch chatState {
        case .composing:
            return .composing
        case .active, .inactive, .gone, .paused:
            return .paused
        }
    }

    private static func chatState(from typingState: TrixTypingState) -> ChatState {
        switch typingState {
        case .composing:
            return .composing
        case .idle, .paused:
            return .paused
        }
    }

    private static func detachedMessage(_ message: Message) -> Message? {
        guard let element = Element.from(string: message.element.stringValue) else {
            return nil
        }

        return Stanza.from(element: element) as? Message
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

    private static func messageHasRecipientKey(_ message: Message, recipientDeviceID: String) -> Bool {
        guard let header = message
            .firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS)?
            .firstChild(name: "header") else {
            return false
        }

        return header
            .filterChildren(name: "key", xmlns: nil)
            .contains { $0.getAttribute("rid") == recipientDeviceID }
    }

    private static func messageTimestamp(_ message: Message, fallback: Date) -> Date {
        guard let delay = message.firstChild(name: "delay", xmlns: "urn:xmpp:delay"),
              let stamp = delay.getAttribute("stamp"),
              let parsed = parseXMPPDelayStamp(stamp) else {
            return fallback
        }

        return parsed
    }

    private static func parseXMPPDelayStamp(_ stamp: String) -> Date? {
        let trimmed = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    private static func mergedTimelineItems(
        _ lhs: [TrixTimelineItem],
        _ rhs: [TrixTimelineItem]
    ) -> [TrixTimelineItem] {
        var byID: [String: TrixTimelineItem] = [:]
        for item in lhs {
            byID[item.id] = item
        }
        for item in rhs {
            if let existingItem = byID[item.id] {
                let mergedItem = item.withDeliveryState(
                    TrixTimelineItem.mergedDeliveryState(
                        existingItem.deliveryState,
                        item.deliveryState
                    )
                )
                byID[item.id] = mergedItem.withReactions(
                    item.reactions.isEmpty ? existingItem.reactions : item.reactions
                )
            } else {
                byID[item.id] = item
            }
        }

        return byID.values.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }
    }

    private static func mergedCallDescriptors(
        _ lhs: [TrixReceivedCallDescriptor],
        _ rhs: [TrixReceivedCallDescriptor]
    ) -> [TrixReceivedCallDescriptor] {
        var byID: [String: TrixReceivedCallDescriptor] = [:]
        for descriptor in lhs {
            byID[descriptor.id] = descriptor
        }
        for descriptor in rhs {
            byID[descriptor.id] = descriptor
        }

        return byID.values.sorted { first, second in
            if first.timestamp != second.timestamp {
                return first.timestamp < second.timestamp
            }

            return first.id < second.id
        }
    }

    private static func requireEncryptedOMEMOPayload(_ message: Message) throws {
        guard message.body == nil,
              let encrypted = message.firstChild(name: "encrypted", xmlns: OMEMOModule.XMLNS),
              let header = encrypted.firstChild(name: "header"),
              !header.filterChildren(name: "key", xmlns: nil as String?).isEmpty else {
            throw TrixClientError.omemoEncryptionFailed
        }
    }

    private static func roomPreview(from item: TrixTimelineItem?) -> String? {
        guard let item else {
            return nil
        }

        let body: String
        if let attachment = item.attachment {
            body = attachment.isSticker ? item.body : "Attachment: \(attachment.filename)"
        } else {
            body = item.body
        }

        if item.isLocalEcho {
            return "You: \(body)"
        }

        return body
    }

    private static func sortedRoomSummaries(_ summaries: [TrixRoomSummary]) -> [TrixRoomSummary] {
        summaries.sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func profile(from vCard: Element?, userID: String) -> TrixUserProfile {
        let displayName = firstNonEmpty(
            vCard?.findChild(name: "FN")?.value,
            vCard?.findChild(name: "NICKNAME")?.value,
            vCard?.findChild(name: "N")?.findChild(name: "GIVEN")?.value,
            displayName(from: userID)
        )
        let metadata = TrixUserMetadata(
            bio: vCard?.findChild(name: "DESC")?.value,
            statusMessage: vCard?.findChild(name: "TITLE")?.value,
            website: vCard?.findChild(name: "URL")?.value
        )
        let avatarURL = vCard?
            .findChild(name: "PHOTO")?
            .findChild(name: "EXTVAL")?
            .value

        return TrixUserProfile(
            userID: userID,
            displayName: displayName,
            avatarURL: avatarURL,
            metadata: metadata
        )
    }

    private static func updatingVCard(
        _ vCard: Element?,
        userID: String,
        update: TrixUserProfileUpdate
    ) -> Element {
        let updated = vCard.map(Element.init(element:)) ?? Element(name: "vCard", xmlns: "vcard-temp")
        updated.xmlns = "vcard-temp"
        updated.removeChildren { child in
            ["FN", "N", "NICKNAME", "TITLE", "DESC", "URL", "JABBERID"].contains(child.name)
        }

        let displayName = nonEmpty(update.displayName) ?? displayName(from: userID)
        updated.addChild(Element(name: "FN", cdata: displayName))

        let name = Element(name: "N")
        name.addChild(Element(name: "GIVEN", cdata: displayName))
        updated.addChild(name)

        updated.addChild(Element(name: "NICKNAME", cdata: displayName))
        addNonEmptyChild(name: "TITLE", value: update.statusMessage, to: updated)
        addNonEmptyChild(name: "DESC", value: update.bio, to: updated)
        addNonEmptyChild(name: "URL", value: update.website, to: updated)
        updated.addChild(Element(name: "JABBERID", cdata: userID))
        return updated
    }

    private static func directoryDefaultVCard(_ vCard: Element?, userID: String) -> (vCard: Element, changed: Bool) {
        let updated = vCard.map(Element.init(element:)) ?? Element(name: "vCard", xmlns: "vcard-temp")
        updated.xmlns = "vcard-temp"
        var changed = vCard == nil

        if firstNonEmpty(updated.findChild(name: "FN")?.value, updated.findChild(name: "NICKNAME")?.value) == nil {
            let displayName = displayName(from: userID)
            updated.addChild(Element(name: "FN", cdata: displayName))
            updated.addChild(Element(name: "NICKNAME", cdata: displayName))
            changed = true
        }

        let hasJabberID = updated.getChildren(name: "JABBERID").contains { child in
            child.value?.caseInsensitiveCompare(userID) == .orderedSame
        }
        if !hasJabberID {
            updated.addChild(Element(name: "JABBERID", cdata: userID))
            changed = true
        }

        return (updated, changed)
    }

    private static func directoryUsers(from response: Iq) -> [TrixUserProfile] {
        guard response.type == .result,
              let query = response.firstChild(name: "query", xmlns: "jabber:iq:search") else {
            return []
        }

        let legacyUsers = query.getChildren(name: "item").compactMap { item -> TrixUserProfile? in
            guard let jid = normalizedDirectoryJID(item.getAttribute("jid")) else {
                return nil
            }

            let displayName = firstNonEmpty(
                item.findChild(name: "nick")?.value,
                item.findChild(name: "fn")?.value,
                item.findChild(name: "first")?.value,
                item.findChild(name: "last")?.value
            )
            return TrixUserProfile(userID: jid, displayName: displayName ?? Self.displayName(from: jid), avatarURL: nil)
        }

        let formUsers = query
            .getChildren(name: "x", xmlns: "jabber:x:data")
            .flatMap { form in
                form.getChildren(name: "item").compactMap { item -> TrixUserProfile? in
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
                    return TrixUserProfile(userID: jid, displayName: displayName ?? Self.displayName(from: jid), avatarURL: nil)
                }
            }

        return deduplicatedUsers(legacyUsers + formUsers)
    }

    private static func deduplicatedUsers(_ users: [TrixUserProfile]) -> [TrixUserProfile] {
        var seen = Set<String>()
        var result: [TrixUserProfile] = []
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static func addNonEmptyChild(name: String, value: String?, to parent: Element) {
        guard let value = nonEmpty(value) else {
            return
        }

        parent.addChild(Element(name: name, cdata: value))
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

    private static func sessionKey(_ session: TrixSession) -> String {
        session.userID.lowercased()
    }

    private static func peerDeviceIdentities(from identities: [Identity], userID: String) -> [TrixPeerDeviceIdentity] {
        identities
            .filter { !$0.own }
            .map { identity in
                let deviceID = String(UInt32(bitPattern: identity.address.deviceId))
                return TrixPeerDeviceIdentity(
                    userID: userID,
                    deviceID: deviceID,
                    fingerprint: identity.fingerprint,
                    visualVerification: TrixDeviceVisualVerification.visualFingerprint(identity.fingerprint),
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

    private static func peerTrustState(from trust: Trust) -> TrixPeerDeviceTrustState {
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
