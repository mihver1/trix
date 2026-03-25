import Foundation

struct RealtimeConnectionUpdate {
    let batch: SafeMessengerEventBatch
}

enum RealtimeWebSocketClientError: LocalizedError {
    case historySyncProgressUnavailable

    var errorDescription: String? {
        switch self {
        case .historySyncProgressUnavailable:
            return "History sync progress updates are only available in the legacy diagnostics path."
        }
    }
}

actor RealtimeWebSocketClient {
    typealias EventHandler = @Sendable (RealtimeConnectionUpdate) async -> Void
    typealias DisconnectHandler = @Sendable (String?) async -> Void

    private let baseURLString: String
    private let accessToken: String
    private let identity: LocalDeviceIdentity
    private let onEvent: EventHandler
    private let onDisconnect: DisconnectHandler

    private var pollLoopTask: Task<Void, Never>?
    private var isRunning = false
    private var checkpoint: String?

    private static let pollIntervalNanoseconds: UInt64 = 1_500_000_000

    init(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        checkpoint: String?,
        onEvent: @escaping EventHandler,
        onDisconnect: @escaping DisconnectHandler
    ) {
        self.baseURLString = baseURLString
        self.accessToken = accessToken
        self.identity = identity
        self.checkpoint = checkpoint
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        pollLoopTask = Task {
            await pollLoop()
        }
    }

    func stop() async {
        await shutdown(notifyDisconnect: false, reason: nil)
    }

    func sendTypingUpdate(chatId: String, isTyping: Bool) throws {
        try TrixCorePersistentBridge.setTyping(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity,
            chatId: chatId,
            isTyping: isTyping
        )
    }

    func sendHistorySyncProgress(
        jobId: String,
        cursorJson: String?,
        completedChunks: UInt64?
    ) throws {
        _ = jobId
        _ = cursorJson
        _ = completedChunks
        throw RealtimeWebSocketClientError.historySyncProgressUnavailable
    }

    private func pollLoop() async {
        while isRunning, !Task.isCancelled {
            do {
                let batch = try TrixCorePersistentBridge.getNewMessengerEvents(
                    baseURLString: baseURLString,
                    accessToken: accessToken,
                    identity: identity,
                    checkpoint: checkpoint
                )
                checkpoint = batch.checkpoint ?? checkpoint

                if !batch.events.isEmpty {
                    await onEvent(RealtimeConnectionUpdate(batch: batch))
                }
            } catch {
                await shutdown(notifyDisconnect: isRunning, reason: error.localizedDescription)
                return
            }

            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
    }

    private func shutdown(notifyDisconnect: Bool, reason: String?) async {
        let shouldNotify = notifyDisconnect && isRunning
        isRunning = false
        pollLoopTask?.cancel()
        pollLoopTask = nil

        if shouldNotify {
            await onDisconnect(reason)
        }
    }
}

func isRecoverableRealtimeSessionReplacement(_ reason: String?) -> Bool {
    _ = reason
    return false
}
