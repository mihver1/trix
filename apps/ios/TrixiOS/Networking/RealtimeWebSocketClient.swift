import Foundation

final class RealtimeWebSocketClient: @unchecked Sendable {
    private let baseURLString: String
    private let accessToken: String
    private let identity: LocalDeviceIdentity
    private let clientLock = NSLock()
    private var cachedClient: FfiMessengerClient?

    init(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity
    ) {
        self.baseURLString = baseURLString
        self.accessToken = accessToken
        self.identity = identity
    }

    static func pollNewEvents(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        checkpoint: String?
    ) throws -> SafeMessengerEventBatch {
        try RealtimeWebSocketClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        .getNewEventsSync(checkpoint: checkpoint)
    }

    func getNewEventsRealtime(checkpoint: String?) async throws -> SafeMessengerEventBatch {
        try await callFFI { client in
            try client.getNewEventsRealtime(checkpoint: checkpoint).trix_safeMessengerEventBatch
        }
    }

    func getNewEvents(checkpoint: String?) async throws -> SafeMessengerEventBatch {
        try await callFFI { client in
            try client.getNewEvents(checkpoint: checkpoint).trix_safeMessengerEventBatch
        }
    }

    func getNewEventsSync(checkpoint: String?) throws -> SafeMessengerEventBatch {
        try client().getNewEvents(checkpoint: checkpoint).trix_safeMessengerEventBatch
    }

    func stop() async {
        guard let client = takeCachedClient() else {
            return
        }
        try? await callFFI(using: client) { client in
            try client.closeRealtime()
        }
    }

    func sendTypingUpdate(chatId: String, isTyping: Bool) async throws {
        try await callFFI { client in
            try client.setTyping(conversationId: chatId, isTyping: isTyping)
        }
    }

    func sendPresencePing(nonce: String? = nil) async throws {
        try await callFFI { client in
            try client.sendPresencePing(nonce: nonce)
        }
    }

    func sendHistorySyncProgress(
        jobId: String,
        cursorJson: String?,
        completedChunks: UInt64?
    ) async throws {
        try await callFFI { client in
            try client.sendHistorySyncProgress(
                jobId: jobId,
                cursorJson: cursorJson,
                completedChunks: completedChunks
            )
        }
    }

    private func client() throws -> FfiMessengerClient {
        clientLock.lock()
        defer { clientLock.unlock() }

        if let cachedClient {
            return cachedClient
        }

        let client = try TrixCorePersistentBridge.openRealtimeMessengerClient(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        cachedClient = client
        return client
    }

    private func takeCachedClient() -> FfiMessengerClient? {
        clientLock.lock()
        defer { clientLock.unlock() }

        let client = cachedClient
        cachedClient = nil
        return client
    }

    private func callFFI<Response: Sendable>(
        _ operation: @escaping @Sendable (FfiMessengerClient) throws -> Response
    ) async throws -> Response {
        let client = try client()
        return try await callFFI(using: client, operation)
    }

    private func callFFI<Response: Sendable>(
        using client: FfiMessengerClient,
        _ operation: @escaping @Sendable (FfiMessengerClient) throws -> Response
    ) async throws -> Response {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation(client))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
