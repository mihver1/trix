import Foundation

@MainActor
final class RealtimeSessionCoordinator {
    typealias BatchHandler = @Sendable (SafeMessengerEventBatch) async -> Void
    typealias DisconnectHandler = @Sendable (String?) async -> Void

    private var checkpoint: String?
    private var activeClient: RealtimeWebSocketClient?
    private var activeLoopTask: Task<Void, Never>?
    private var activeAccessToken: String?
    private var activeBaseURLString: String?
    private var activeDeviceID: String?
    private var connectionID = UUID()

    var hasActiveLoop: Bool {
        activeLoopTask != nil
    }

    func replaceCheckpoint(_ checkpoint: String?) {
        self.checkpoint = checkpoint
    }

    func clearCheckpoint() {
        checkpoint = nil
    }

    func start(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        onBatch: @escaping BatchHandler,
        onDisconnect: @escaping DisconnectHandler
    ) async {
        let normalizedBaseURL = normalize(baseURLString)
        if hasActiveLoop,
           activeAccessToken == accessToken,
           activeBaseURLString == normalizedBaseURL,
           activeDeviceID == identity.deviceId {
            return
        }

        await stop()

        let connectionID = UUID()
        self.connectionID = connectionID
        activeBaseURLString = normalizedBaseURL
        activeAccessToken = accessToken
        activeDeviceID = identity.deviceId

        let client = RealtimeWebSocketClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        activeClient = client
        activeLoopTask = Task { [weak self] in
            await self?.runRealtimeLoop(
                client: client,
                connectionID: connectionID,
                onBatch: onBatch,
                onDisconnect: onDisconnect
            )
        }
    }

    func stop() async {
        let suspendedSession = suspendActiveSession()
        suspendedSession.loopTask?.cancel()

        if let client = suspendedSession.client {
            await client.stop()
        }
        if let loopTask = suspendedSession.loopTask {
            await loopTask.value
        }
    }

    func disconnect() {
        let suspendedSession = suspendActiveSession()
        suspendedSession.loopTask?.cancel()

        guard suspendedSession.client != nil || suspendedSession.loopTask != nil else {
            return
        }

        Task {
            if let client = suspendedSession.client {
                await client.stop()
            }
            if let loopTask = suspendedSession.loopTask {
                await loopTask.value
            }
        }
    }

    func pollNewEvents(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) async throws -> SafeMessengerEventBatch {
        let batch = try await RealtimeWebSocketClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        .getNewEvents(checkpoint: checkpoint)
        checkpoint = batch.checkpoint ?? checkpoint
        return batch
    }

    @discardableResult
    func sendTypingUpdate(chatId: String, isTyping: Bool) async throws -> Bool {
        guard let activeClient else {
            return false
        }

        try await activeClient.sendTypingUpdate(chatId: chatId, isTyping: isTyping)
        return true
    }

    @discardableResult
    func sendHistorySyncProgress(
        jobId: String,
        cursorJson: String?,
        completedChunks: UInt64?
    ) async throws -> Bool {
        guard let activeClient else {
            return false
        }

        try await activeClient.sendHistorySyncProgress(
            jobId: jobId,
            cursorJson: cursorJson,
            completedChunks: completedChunks
        )
        return true
    }

    private func runRealtimeLoop(
        client: RealtimeWebSocketClient,
        connectionID: UUID,
        onBatch: @escaping BatchHandler,
        onDisconnect: @escaping DisconnectHandler
    ) async {
        while !Task.isCancelled {
            do {
                let batch = try await client.getNewEventsRealtime(checkpoint: checkpoint)
                guard !Task.isCancelled else {
                    return
                }
                guard applyRealtimeBatch(batch, connectionID: connectionID) else {
                    return
                }
                await onBatch(batch)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                let suspendedSession = suspendActiveSession(matching: connectionID)
                if let client = suspendedSession.client {
                    await client.stop()
                }
                guard suspendedSession.client != nil || suspendedSession.loopTask != nil else {
                    return
                }
                await onDisconnect(error.localizedDescription)
                return
            }
        }
    }

    private func applyRealtimeBatch(
        _ batch: SafeMessengerEventBatch,
        connectionID: UUID
    ) -> Bool {
        guard self.connectionID == connectionID else {
            return false
        }

        checkpoint = batch.checkpoint ?? checkpoint
        return true
    }

    private func suspendActiveSession(
        matching expectedConnectionID: UUID? = nil
    ) -> (client: RealtimeWebSocketClient?, loopTask: Task<Void, Never>?) {
        guard expectedConnectionID == nil || connectionID == expectedConnectionID else {
            return (nil, nil)
        }

        let suspendedSession = (client: activeClient, loopTask: activeLoopTask)
        activeClient = nil
        activeLoopTask = nil
        activeAccessToken = nil
        activeBaseURLString = nil
        activeDeviceID = nil
        connectionID = UUID()
        return suspendedSession
    }

    private func normalize(_ baseURLString: String) -> String {
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
