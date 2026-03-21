import Foundation

struct RealtimeConnectionUpdate {
    let event: FfiRealtimeEvent
}

actor RealtimeWebSocketClient {
    typealias EventHandler = @Sendable (RealtimeConnectionUpdate) async -> Void
    typealias DisconnectHandler = @Sendable (String?) async -> Void

    private let apiClient: FfiServerApiClient
    private let websocket: FfiServerWebSocketClient
    private let realtimeDriver: FfiRealtimeDriver
    private let historyStore: FfiLocalHistoryStore
    private let syncCoordinator: FfiSyncCoordinator
    private let onEvent: EventHandler
    private let onDisconnect: DisconnectHandler

    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var isRunning = false

    init(
        baseURLString: String,
        accessToken: String,
        databasePath: URL,
        statePath: URL,
        onEvent: @escaping EventHandler,
        onDisconnect: @escaping DisconnectHandler
    ) throws {
        apiClient = try FfiServerApiClient(baseUrl: baseURLString)
        try apiClient.setAccessToken(accessToken: accessToken)
        websocket = try apiClient.connectWebsocket()
        realtimeDriver = try FfiRealtimeDriver()
        historyStore = try FfiLocalHistoryStore.newPersistent(databasePath: databasePath.path)
        syncCoordinator = try FfiSyncCoordinator.newPersistent(statePath: statePath.path)
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        receiveLoopTask = Task {
            await receiveLoop()
        }
        heartbeatTask = Task {
            await heartbeatLoop()
        }
    }

    func stop() async {
        await shutdown(notifyDisconnect: false, reason: nil)
    }

    func sendTypingUpdate(chatId: UUID, isTyping: Bool) async throws {
        try websocket.sendTypingUpdate(chatId: chatId.uuidString, isTyping: isTyping)
    }

    func sendHistorySyncProgress(
        jobId: UUID,
        cursorJson: JSONValue?,
        completedChunks: UInt64?
    ) async throws {
        let cursorJSONString: String?
        if let cursorJson {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(cursorJson)
            cursorJSONString = String(data: data, encoding: .utf8)
        } else {
            cursorJSONString = nil
        }

        try websocket.sendHistorySyncProgress(
            jobId: jobId.uuidString,
            cursorJson: cursorJSONString,
            completedChunks: completedChunks
        )
    }

    private func receiveLoop() async {
        while isRunning, !Task.isCancelled {
            do {
                guard let event = try realtimeDriver.nextWebsocketEvent(
                    websocket: websocket,
                    coordinator: syncCoordinator,
                    store: historyStore,
                    autoAck: true
                ) else {
                    await shutdown(notifyDisconnect: isRunning, reason: "Realtime websocket closed.")
                    return
                }

                await onEvent(RealtimeConnectionUpdate(event: event))
            } catch {
                await shutdown(notifyDisconnect: isRunning, reason: error.localizedDescription)
                return
            }
        }
    }

    private func heartbeatLoop() async {
        while isRunning, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)

            guard isRunning, !Task.isCancelled else {
                return
            }

            do {
                try websocket.sendPresencePing(nonce: nil)
            } catch {
                await shutdown(notifyDisconnect: isRunning, reason: error.localizedDescription)
                return
            }
        }
    }

    private func shutdown(notifyDisconnect: Bool, reason: String?) async {
        let shouldNotify = notifyDisconnect && isRunning

        isRunning = false
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        _ = try? websocket.closeSocket()

        if shouldNotify {
            await onDisconnect(reason)
        }
    }
}

func isRecoverableRealtimeSessionReplacement(_ reason: String?) -> Bool {
    switch reason {
    case "replaced by a newer websocket session", "server shutting down":
        return true
    default:
        return false
    }
}
