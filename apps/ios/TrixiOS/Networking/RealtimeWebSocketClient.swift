import Foundation

struct RealtimeConnectionUpdate {
    let frame: FfiWebSocketServerFrame
    let event: FfiRealtimeEvent
    let inboxItems: [InboxItem]
}

actor RealtimeWebSocketClient {
    typealias EventHandler = @Sendable (RealtimeConnectionUpdate) async -> Void
    typealias DisconnectHandler = @Sendable (String?) async -> Void

    private let websocket: FfiServerWebSocketClient
    private let realtimeDriver: FfiRealtimeDriver
    private let historyDatabasePath: String
    private let syncStatePath: String
    private let onEvent: EventHandler
    private let onDisconnect: DisconnectHandler

    private var receiveLoopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var isRunning = false

    init(
        baseURLString: String,
        accessToken: String,
        identity: LocalDeviceIdentity,
        onEvent: @escaping EventHandler,
        onDisconnect: @escaping DisconnectHandler
    ) throws {
        let bindings = try TrixCorePersistentBridge.makeRealtimeBindings(
            baseURLString: baseURLString,
            accessToken: accessToken,
            identity: identity
        )
        websocket = bindings.websocket
        realtimeDriver = bindings.realtimeDriver
        historyDatabasePath = bindings.historyDatabasePath
        syncStatePath = bindings.syncStatePath
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

    private func receiveLoop() async {
        while isRunning, !Task.isCancelled {
            do {
                guard let frame = try websocket.nextFrame() else {
                    await shutdown(notifyDisconnect: isRunning, reason: "Realtime websocket closed.")
                    return
                }

                let coordinator = try FfiSyncCoordinator.newPersistent(statePath: syncStatePath)
                let store = try FfiLocalHistoryStore.newPersistent(databasePath: historyDatabasePath)
                let event = try realtimeDriver.processWebsocketFrame(
                    coordinator: coordinator,
                    store: store,
                    frame: frame
                )

                if !event.outboundAckInboxIds.isEmpty {
                    try websocket.sendAck(inboxIds: event.outboundAckInboxIds)
                }

                await onEvent(
                    RealtimeConnectionUpdate(
                        frame: frame,
                        event: event,
                        inboxItems: frame.trix_inboxItems
                    )
                )
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

        try? websocket.close()

        if shouldNotify {
            await onDisconnect(reason)
        }
    }
}

private extension FfiWebSocketServerFrame {
    var trix_inboxItems: [InboxItem] {
        inbox?.items.map(\.trix_inboxItem) ?? []
    }
}

private extension FfiInboxItem {
    var trix_inboxItem: InboxItem {
        InboxItem(
            inboxId: inboxId,
            message: message.trix_messageEnvelope
        )
    }
}

private extension FfiMessageEnvelope {
    var trix_messageEnvelope: MessageEnvelope {
        MessageEnvelope(
            messageId: messageId,
            chatId: chatId,
            serverSeq: serverSeq,
            senderAccountId: senderAccountId,
            senderDeviceId: senderDeviceId,
            epoch: epoch,
            messageKind: messageKind.trix_messageKind,
            contentType: contentType.trix_contentType,
            ciphertextB64: ciphertext.base64EncodedString(),
            aadJson: aadJson.trix_jsonValue,
            createdAtUnix: createdAtUnix
        )
    }
}

private extension FfiMessageKind {
    var trix_messageKind: MessageKind {
        switch self {
        case .application:
            return .application
        case .commit:
            return .commit
        case .welcomeRef:
            return .welcomeRef
        case .system:
            return .system
        }
    }
}

private extension FfiContentType {
    var trix_contentType: ContentType {
        switch self {
        case .text:
            return .text
        case .reaction:
            return .reaction
        case .receipt:
            return .receipt
        case .attachment:
            return .attachment
        case .chatEvent:
            return .chatEvent
        }
    }
}

private extension String {
    var trix_jsonValue: JSONValue {
        guard let data = data(using: .utf8) else {
            return .string(self)
        }

        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .string(self)
    }
}
