import Foundation

enum RealtimeWebSocketClientError: LocalizedError {
    case invalidBaseURL(String)
    case unsupportedScheme(String)
    case invalidFrameEncoding

    var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            return "Invalid base URL for websocket transport: \(value)"
        case let .unsupportedScheme(value):
            return "Unsupported websocket base scheme: \(value)"
        case .invalidFrameEncoding:
            return "Failed to encode websocket frame payload."
        }
    }
}

actor RealtimeWebSocketClient {
    typealias FrameHandler = @Sendable (WebSocketServerFrame) async -> Void
    typealias DisconnectHandler = @Sendable (String?) async -> Void

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let onFrame: FrameHandler
    private let onDisconnect: DisconnectHandler

    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var isRunning = false

    init(
        baseURLString: String,
        accessToken: String,
        onFrame: @escaping FrameHandler,
        onDisconnect: @escaping DisconnectHandler
    ) throws {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)

        var request = URLRequest(url: try Self.websocketURL(baseURLString: baseURLString))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder

        self.onFrame = onFrame
        self.onDisconnect = onDisconnect
    }

    func start() {
        guard !isRunning else {
            return
        }

        isRunning = true
        task.resume()

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

    func sendAck(inboxIds: [UInt64]) async throws {
        guard !inboxIds.isEmpty else {
            return
        }

        try await send(WebSocketAckClientFrame(inboxIds: inboxIds))
    }

    private func receiveLoop() async {
        while isRunning, !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    try await handleIncomingPayload(Data(text.utf8))
                case let .data(data):
                    try await handleIncomingPayload(data)
                @unknown default:
                    continue
                }
            } catch {
                await shutdown(
                    notifyDisconnect: isRunning,
                    reason: Self.disconnectReason(for: task, fallback: error.localizedDescription)
                )
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
                try await send(WebSocketPresencePingClientFrame(nonce: nil))
            } catch {
                await shutdown(
                    notifyDisconnect: isRunning,
                    reason: Self.disconnectReason(for: task, fallback: error.localizedDescription)
                )
                return
            }
        }
    }

    private func handleIncomingPayload(_ payload: Data) async throws {
        let frame = try decoder.decode(WebSocketServerFrame.self, from: payload)
        await onFrame(frame)
    }

    private func send<Frame: Encodable>(_ frame: Frame) async throws {
        guard isRunning else {
            return
        }

        let payload = try encoder.encode(frame)
        guard let text = String(data: payload, encoding: .utf8) else {
            throw RealtimeWebSocketClientError.invalidFrameEncoding
        }

        try await task.send(.string(text))
    }

    private func shutdown(notifyDisconnect: Bool, reason: String?) async {
        let shouldNotify = notifyDisconnect && isRunning

        isRunning = false
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        task.cancel(with: .goingAway, reason: reason?.data(using: .utf8))
        session.invalidateAndCancel()

        if shouldNotify {
            await onDisconnect(reason)
        }
    }

    private static func websocketURL(baseURLString: String) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? trimmed : "\(trimmed)/"

        guard let baseURL = URL(string: normalized), baseURL.scheme != nil, baseURL.host != nil else {
            throw RealtimeWebSocketClientError.invalidBaseURL(baseURLString)
        }

        guard let httpURL = URL(string: "v0/ws", relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: true)
        else {
            throw RealtimeWebSocketClientError.invalidBaseURL(baseURLString)
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        case let .some(value):
            throw RealtimeWebSocketClientError.unsupportedScheme(value)
        case .none:
            throw RealtimeWebSocketClientError.invalidBaseURL(baseURLString)
        }

        guard let websocketURL = components.url else {
            throw RealtimeWebSocketClientError.invalidBaseURL(baseURLString)
        }

        return websocketURL
    }

    private static func disconnectReason(
        for task: URLSessionWebSocketTask,
        fallback: String
    ) -> String {
        if let closeReason = task.closeReason,
           let closeReasonString = String(data: closeReason, encoding: .utf8),
           !closeReasonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return closeReasonString
        }

        if task.closeCode != .invalid {
            return "Websocket closed with code \(task.closeCode.rawValue)."
        }

        return fallback
    }
}
