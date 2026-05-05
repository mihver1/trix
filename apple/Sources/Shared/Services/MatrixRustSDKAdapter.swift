import Foundation
import MatrixRustSDK
#if os(iOS)
import UIKit
#endif

actor MatrixRustSDKAdapter: MatrixService {
    private var client: Client?
    private var syncService: SyncService?
    private var syncTask: Task<Void, Never>?
    private var roomListListener: SDKRoomListListener?
    private var roomListHandle: RoomListEntriesWithDynamicAdaptersResult?
    private var roomsByID: [String: Room] = [:]
    private var timelineStateByRoomID: [String: SDKTimelineState] = [:]

    func login(userID: String, password: String, serverURL: URL) async throws -> MatrixSession {
        let localpart = try Self.localpart(from: userID)
        let storeID = UUID().uuidString
        let paths = try Self.paths(for: storeID)
        let client = try await makeClient(serverURL: serverURL, paths: paths)

        try await client.login(
            username: localpart,
            password: password,
            initialDeviceName: Self.defaultDeviceName,
            deviceId: nil
        )

        self.client = client
        let sdkSession = try client.session()
        return MatrixSession(sdkSession: sdkSession, sdkStoreID: storeID)
    }

    func restore(session: MatrixSession) async throws -> MatrixAccount {
        let paths = try Self.paths(for: session.sdkStoreID)
        let client = try await ClientBuilder()
            .sessionPaths(
                dataPath: paths.data.path(percentEncoded: false),
                cachePath: paths.cache.path(percentEncoded: false)
            )
            .homeserverUrl(url: session.homeserverURL.absoluteString)
            .build()

        try await client.restoreSession(session: session.sdkSession)
        self.client = client

        return MatrixAccount(
            userID: session.userID,
            displayName: Self.displayName(from: session.userID),
            deviceID: session.deviceID
        )
    }

    func logout(session: MatrixSession) async throws {
        var sdkLogoutError: Error?
        do {
            let activeClient = try await resolvedClient(session: session)
            try await activeClient.logout()
        } catch {
            sdkLogoutError = error
        }

        await syncService?.stop()
        syncTask?.cancel()
        syncTask = nil
        syncService = nil
        roomListHandle = nil
        roomListListener = nil
        roomsByID = [:]
        timelineStateByRoomID = [:]
        client = nil

        try? FileManager.default.removeItem(at: Self.dataRoot(for: session.sdkStoreID))
        try? FileManager.default.removeItem(at: Self.cacheRoot(for: session.sdkStoreID))

        if let sdkLogoutError {
            throw sdkLogoutError
        }
    }

    func rooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        let sdkRooms = cachedRooms(client: client)
        roomsByID = Dictionary(uniqueKeysWithValues: sdkRooms.map { ($0.id(), $0) })

        let joinedRooms = await Self.joinedRooms(from: sdkRooms)
        var summaries: [MatrixRoomSummary] = []
        for room in joinedRooms {
            summaries.append(await Self.summary(from: room))
        }

        return summaries.sorted { lhs, rhs in
            lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    func timeline(roomID: String, session: MatrixSession) async throws -> [MatrixTimelineItem] {
        let room = try await room(for: roomID, session: session)

        if timelineStateByRoomID[roomID] == nil {
            let timeline = try await room.timeline()
            let listener = SDKTimelineListener()
            let handle = await timeline.addListener(listener: listener)
            timelineStateByRoomID[roomID] = SDKTimelineState(
                timeline: timeline,
                listener: listener,
                handle: handle
            )
            for _ in 0..<6 {
                if !listener.snapshot().isEmpty {
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if listener.snapshot().isEmpty {
                _ = try? await timeline.paginateBackwards(numEvents: 30)
            }
        }

        guard let state = timelineStateByRoomID[roomID] else {
            return []
        }

        return state.listener.snapshot().compactMap { item in
            Self.timelineItem(from: item, roomID: roomID)
        }
    }

    func sendText(_ text: String, roomID: String, session: MatrixSession) async throws -> MatrixTimelineItem {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw MatrixClientError.emptyMessage
        }

        _ = try await timeline(roomID: roomID, session: session)
        guard let state = timelineStateByRoomID[roomID] else {
            throw MatrixClientError.missingSession
        }

        let message = messageEventContentFromMarkdown(md: body)
        _ = try await state.timeline.send(msg: message)

        return MatrixTimelineItem(
            id: "$local-\(UUID().uuidString)",
            roomID: roomID,
            sender: session.userID,
            timestamp: Date(),
            body: body,
            isLocalEcho: true
        )
    }

    func createEncryptedDirectRoom(
        inviteeUserID: String,
        name: String,
        session: MatrixSession
    ) async throws -> MatrixRoomSummary {
        let client = try await resolvedClient(session: session)
        let roomID = try await client.createRoom(
            request: CreateRoomParameters(
                name: name,
                isEncrypted: true,
                isDirect: true,
                visibility: .private,
                preset: .privateChat,
                invite: [inviteeUserID]
            )
        )

        try await ensureSyncStarted(client: client)
        try? await Task.sleep(for: .seconds(1))

        guard let room = try client.getRoom(roomId: roomID) else {
            throw MatrixClientError.roomUnavailable
        }

        roomsByID[roomID] = room
        return await Self.summary(from: room)
    }

    func invitations(session: MatrixSession) async throws -> [MatrixRoomInvite] {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        let sdkRooms = cachedRooms(client: client)
        roomsByID = Dictionary(uniqueKeysWithValues: sdkRooms.map { ($0.id(), $0) })

        var invitations: [MatrixRoomInvite] = []
        for room in await Self.invitedRooms(from: sdkRooms) {
            invitations.append(await Self.invitation(from: room))
        }

        return invitations.sorted { lhs, rhs in
            lhs.receivedAt > rhs.receivedAt
        }
    }

    func acceptInvitation(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        let room = try await invitedRoom(for: roomID, session: session)
        try await room.join()
        roomsByID[room.id()] = room
        try? await Task.sleep(for: .seconds(1))
        return await Self.summary(from: room)
    }

    func declineInvitation(roomID: String, session: MatrixSession) async throws {
        let room = try await invitedRoom(for: roomID, session: session)
        try await room.leave()
        roomsByID.removeValue(forKey: room.id())
        timelineStateByRoomID.removeValue(forKey: room.id())
        try? await Task.sleep(for: .milliseconds(500))
    }

    func joinInvitedRooms(session: MatrixSession) async throws -> [MatrixRoomSummary] {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        var joinedRooms: [MatrixRoomSummary] = []
        for _ in 0..<10 {
            let invitedRooms = await Self.invitedRooms(from: cachedRooms(client: client))
            if invitedRooms.isEmpty {
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            for room in invitedRooms {
                try await room.join()
                roomsByID[room.id()] = room
                joinedRooms.append(await Self.summary(from: room))
            }
            break
        }

        return joinedRooms
    }

    func joinRoom(roomID: String, session: MatrixSession) async throws -> MatrixRoomSummary {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        for _ in 0..<15 {
            if let room = try client.getRoom(roomId: roomID) {
                try await room.join()
                roomsByID[room.id()] = room
                try? await Task.sleep(for: .seconds(1))
                return await Self.summary(from: room)
            }
            do {
                let joinedRoom = try await client.joinRoomById(roomId: roomID)
                roomsByID[joinedRoom.id()] = joinedRoom
                try? await Task.sleep(for: .seconds(1))
                return await Self.summary(from: joinedRoom)
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        throw MatrixClientError.roomUnavailable
    }

    private func resolvedClient(session: MatrixSession) async throws -> Client {
        if let client {
            return client
        }

        _ = try await restore(session: session)
        guard let client else {
            throw MatrixClientError.missingSession
        }
        return client
    }

    private func room(for roomID: String, session: MatrixSession) async throws -> Room {
        if let room = roomsByID[roomID] {
            return room
        }

        _ = try await rooms(session: session)
        guard let room = roomsByID[roomID] else {
            throw MatrixClientError.roomUnavailable
        }
        return room
    }

    private func invitedRoom(for roomID: String, session: MatrixSession) async throws -> Room {
        let client = try await resolvedClient(session: session)
        try await ensureSyncStarted(client: client)

        for _ in 0..<8 {
            if let room = roomsByID[roomID], await Self.isInvited(room) {
                return room
            }

            if let room = try client.getRoom(roomId: roomID), await Self.isInvited(room) {
                roomsByID[room.id()] = room
                return room
            }

            let rooms = cachedRooms(client: client)
            roomsByID = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id(), $0) })
            if let room = rooms.first(where: { $0.id() == roomID }), await Self.isInvited(room) {
                return room
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        throw MatrixClientError.inviteUnavailable
    }

    private func cachedRooms(client: Client) -> [Room] {
        var roomsByID: [String: Room] = Dictionary(uniqueKeysWithValues: client.rooms().map { ($0.id(), $0) })
        for room in roomListListener?.snapshot() ?? [] {
            roomsByID[room.id()] = room
        }
        return Array(roomsByID.values)
    }

    private func makeClient(serverURL: URL, paths: SDKSessionPaths) async throws -> Client {
        try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: serverURL.absoluteString)
            .sessionPaths(
                dataPath: paths.data.path(percentEncoded: false),
                cachePath: paths.cache.path(percentEncoded: false)
            )
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .build()
    }

    private func ensureSyncStarted(client: Client) async throws {
        if syncService != nil {
            return
        }

        let syncService = try await client.syncService().finish()
        let listener = SDKRoomListListener()
        let roomListService = syncService.roomListService()
        let handle = try await roomListService
            .allRooms()
            .entriesWithDynamicAdapters(pageSize: 100, listener: listener)
        _ = handle.controller().setFilter(kind: .all(filters: []))

        self.syncService = syncService
        self.roomListListener = listener
        self.roomListHandle = handle
        self.syncTask = Task {
            await syncService.start()
        }

        try? await Task.sleep(for: .milliseconds(750))
    }
}

private struct SDKSessionPaths {
    let data: URL
    let cache: URL
}

private struct SDKTimelineState {
    let timeline: Timeline
    let listener: SDKTimelineListener
    let handle: TaskHandle
}

private final class SDKRoomListListener: RoomListEntriesListener, @unchecked Sendable {
    private let lock = NSLock()
    private var rooms: [Room] = []

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        lock.withLock {
            for update in roomEntriesUpdate {
                switch update {
                case .append(let values):
                    rooms.append(contentsOf: values)
                case .clear:
                    rooms.removeAll()
                case .pushFront(let room):
                    rooms.insert(room, at: 0)
                case .pushBack(let room):
                    rooms.append(room)
                case .popFront:
                    if !rooms.isEmpty {
                        rooms.removeFirst()
                    }
                case .popBack:
                    _ = rooms.popLast()
                case .insert(let index, let room):
                    rooms.insert(room, at: min(Int(index), rooms.count))
                case .set(let index, let room):
                    let roomIndex = Int(index)
                    guard rooms.indices.contains(roomIndex) else {
                        return
                    }
                    rooms[roomIndex] = room
                case .remove(let index):
                    let roomIndex = Int(index)
                    guard rooms.indices.contains(roomIndex) else {
                        return
                    }
                    rooms.remove(at: roomIndex)
                case .truncate(let length):
                    let keptCount = min(Int(length), rooms.count)
                    rooms.removeSubrange(keptCount..<rooms.count)
                case .reset(values: let values):
                    rooms = values
                }
            }
        }
    }

    func snapshot() -> [Room] {
        lock.withLock {
            rooms
        }
    }
}

private final class SDKTimelineListener: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimelineItem] = []

    func onUpdate(diff: [TimelineDiff]) {
        lock.withLock {
            for update in diff {
                switch update {
                case .append(let values):
                    items.append(contentsOf: values)
                case .clear:
                    items.removeAll()
                case .pushFront(let item):
                    items.insert(item, at: 0)
                case .pushBack(let item):
                    items.append(item)
                case .popFront:
                    if !items.isEmpty {
                        items.removeFirst()
                    }
                case .popBack:
                    _ = items.popLast()
                case .insert(let index, let item):
                    items.insert(item, at: min(Int(index), items.count))
                case .set(let index, let item):
                    let itemIndex = Int(index)
                    guard items.indices.contains(itemIndex) else {
                        return
                    }
                    items[itemIndex] = item
                case .remove(let index):
                    let itemIndex = Int(index)
                    guard items.indices.contains(itemIndex) else {
                        return
                    }
                    items.remove(at: itemIndex)
                case .truncate(let length):
                    let keptCount = min(Int(length), items.count)
                    items.removeSubrange(keptCount..<items.count)
                case .reset(values: let values):
                    items = values
                }
            }
        }
    }

    func snapshot() -> [TimelineItem] {
        lock.withLock {
            items
        }
    }
}

private extension MatrixRustSDKAdapter {
    static var defaultDeviceName: String {
        #if os(iOS)
        return "Trix iOS"
        #elseif os(macOS)
        return Host.current().localizedName ?? "This Mac"
        #else
        return "Trix"
        #endif
    }

    static func localpart(from userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"),
              let separator = trimmed.firstIndex(of: ":") else {
            throw MatrixClientError.invalidCredentials
        }

        let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
        let serverName = String(trimmed[trimmed.index(after: separator)...])
        guard !localpart.isEmpty,
              serverName == MatrixClientConfiguration.serverName else {
            throw MatrixClientError.invalidCredentials
        }

        return localpart
    }

    static func paths(for storeID: String) throws -> SDKSessionPaths {
        let data = dataRoot(for: storeID)
        let cache = cacheRoot(for: storeID)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return SDKSessionPaths(data: data, cache: cache)
    }

    static func dataRoot(for storeID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrixMatrix", isDirectory: true)
            .appendingPathComponent(storeID, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
    }

    static func cacheRoot(for storeID: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrixMatrix", isDirectory: true)
            .appendingPathComponent(storeID, isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }

    static func displayName(from userID: String) -> String {
        let withoutAt = userID.dropFirst()
        let localpart = withoutAt.split(separator: ":").first.map(String.init) ?? String(withoutAt)
        return localpart.capitalized
    }

    static func summary(from room: Room) async -> MatrixRoomSummary {
        let info = try? await room.roomInfo()
        let latestEvent = await room.latestEvent()
        let preview = messageBody(from: latestEvent) ?? "No messages yet"
        let timestamp = latestTimestamp(from: latestEvent)
        let sdkEncryptionState = await room.isEncrypted()
        let isEncrypted = info?.encryptionState == .encrypted || sdkEncryptionState
        let isDirect: Bool
        if let infoIsDirect = info?.isDirect {
            isDirect = infoIsDirect
        } else {
            isDirect = await room.isDirect()
        }

        return MatrixRoomSummary(
            id: room.id(),
            name: info?.displayName ?? room.displayName() ?? room.id(),
            kind: isDirect ? .direct : .group,
            isEncrypted: isEncrypted,
            unreadCount: Int(info?.numUnreadNotifications ?? info?.numUnreadMessages ?? 0),
            lastMessagePreview: preview,
            lastActivityAt: timestamp
        )
    }

    static func joinedRooms(from rooms: [Room]) async -> [Room] {
        var joinedRooms: [Room] = []
        for room in rooms {
            if await isJoined(room) {
                joinedRooms.append(room)
            }
        }
        return joinedRooms
    }

    static func invitedRooms(from rooms: [Room]) async -> [Room] {
        var invitedRooms: [Room] = []
        for room in rooms {
            if await isInvited(room) {
                invitedRooms.append(room)
            }
        }
        return invitedRooms
    }

    static func invitation(from room: Room) async -> MatrixRoomInvite {
        let info = try? await room.roomInfo()
        let latestEvent = await room.latestEvent()
        let sdkEncryptionState = await room.isEncrypted()
        let isEncrypted = info?.encryptionState == .encrypted || sdkEncryptionState
        let inviter: RoomMember?
        if let infoInviter = info?.inviter {
            inviter = infoInviter
        } else {
            inviter = try? await room.inviter()
        }
        let isDirect: Bool
        if let infoIsDirect = info?.isDirect {
            isDirect = infoIsDirect
        } else {
            isDirect = await room.isDirect()
        }

        return MatrixRoomInvite(
            id: room.id(),
            roomName: info?.displayName ?? room.displayName() ?? room.id(),
            kind: isDirect ? .direct : .group,
            isEncrypted: isEncrypted,
            inviterUserID: inviter?.userId,
            inviterDisplayName: inviter?.displayName,
            receivedAt: latestTimestamp(from: latestEvent)
        )
    }

    static func isJoined(_ room: Room) async -> Bool {
        let info = try? await room.roomInfo()
        return info?.membership == .joined || room.membership() == .joined
    }

    static func isInvited(_ room: Room) async -> Bool {
        let info = try? await room.roomInfo()
        return info?.membership == .invited || room.membership() == .invited
    }

    static func timelineItem(from sdkItem: TimelineItem, roomID: String) -> MatrixTimelineItem? {
        guard let event = sdkItem.asEvent(),
              case let .msgLike(content: msgLike) = event.content,
              case let .message(content: messageContent) = msgLike.kind else {
            return nil
        }

        return MatrixTimelineItem(
            id: sdkItem.uniqueId().id,
            roomID: roomID,
            sender: event.sender,
            timestamp: Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1_000),
            body: messageContent.body,
            isLocalEcho: event.isOwn
        )
    }

    static func latestTimestamp(from latestEvent: LatestEventValue) -> Date {
        switch latestEvent {
        case .remote(let timestamp, _, _, _, _),
             .remoteInvite(let timestamp, _, _),
             .local(let timestamp, _, _, _, _):
            return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
        case .none:
            return .distantPast
        }
    }

    static func messageBody(from latestEvent: LatestEventValue) -> String? {
        switch latestEvent {
        case .remote(_, let sender, _, _, let content),
             .local(_, let sender, _, let content, _):
            if let body = messageBody(from: content) {
                return "\(sender): \(body)"
            }
            return nil
        case .remoteInvite(_, let inviter, _):
            return inviter.map { "\($0) invited you" }
        case .none:
            return nil
        }
    }

    static func messageBody(from content: TimelineItemContent) -> String? {
        guard case let .msgLike(content: msgLike) = content else {
            return nil
        }

        switch msgLike.kind {
        case .message(let message):
            return message.body
        case .sticker(let body, _, _):
            return body
        case .unableToDecrypt:
            return "Encrypted message unavailable"
        case .redacted:
            return "Message deleted"
        default:
            return nil
        }
    }
}

private extension MatrixSession {
    init(sdkSession: Session, sdkStoreID: String) {
        self.init(
            userID: sdkSession.userId,
            deviceID: sdkSession.deviceId,
            homeserverURL: URL(string: sdkSession.homeserverUrl) ?? MatrixClientConfiguration.homeserverURL,
            accessToken: sdkSession.accessToken,
            refreshToken: sdkSession.refreshToken,
            oidcData: sdkSession.oidcData,
            sdkStoreID: sdkStoreID,
            createdAt: Date()
        )
    }

    var sdkSession: Session {
        Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userId: userID,
            deviceId: deviceID,
            homeserverUrl: homeserverURL.absoluteString,
            oidcData: oidcData,
            slidingSyncVersion: .native
        )
    }
}
