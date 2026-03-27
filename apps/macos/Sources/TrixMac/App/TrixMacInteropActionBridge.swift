import AppKit
import Foundation
import Network

private final class TrixMacInteropTCPSendOnce: @unchecked Sendable {
    private var sent = false
    private let lock = NSLock()

    func markIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if sent { return false }
        sent = true
        return true
    }
}

@MainActor
enum TrixMacInteropActionBridge {
    static func performIfNeeded(configuration: MacUITestLaunchConfiguration) {
        guard configuration.isEnabled else { return }
        guard interopSurfacesEnabled(configuration) else { return }

        let result: TrixMacInteropActionResult
        do {
            let action = try loadAction(configuration: configuration)
            result = execute(action: action)
        } catch {
            result = .failure(error.localizedDescription)
        }

        do {
            try emitResult(result, configuration: configuration)
        } catch {
            assertionFailure("Interop result emit failed: \(error.localizedDescription)")
        }
    }

    private static func interopSurfacesEnabled(_ configuration: MacUITestLaunchConfiguration) -> Bool {
        let hasAction =
            normalizedString(configuration.interopActionJSON) != nil
            || normalizedString(configuration.interopActionInputFileName) != nil
        let hasSink =
            normalizedString(configuration.interopResultOutputFileName) != nil
            || normalizedString(configuration.interopResultPasteboardName) != nil
            || tcpPort(configuration.interopResultTCPPort) != nil
        return hasAction && hasSink
    }

    private static func normalizedString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func tcpPort(_ value: String?) -> UInt16? {
        guard let trimmed = normalizedString(value), let port = UInt16(trimmed), port > 0 else {
            return nil
        }
        return port
    }

    private static func documentsDirectory() throws -> URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw TrixMacInteropActionBridgeError.missingDocumentsDirectory
        }
        return url
    }

    private static func loadAction(configuration: MacUITestLaunchConfiguration) throws -> TrixMacInteropAction {
        if let json = configuration.interopActionJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !json.isEmpty {
            return try TrixMacInteropAction.decode(json)
        }
        guard let fileName = configuration.interopActionInputFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileName.isEmpty else {
            throw TrixMacInteropActionBridgeError.missingInteropAction
        }
        let docs = try documentsDirectory()
        let data = try Data(contentsOf: docs.appendingPathComponent(fileName))
        return try JSONDecoder().decode(TrixMacInteropAction.self, from: data)
    }

    private static func execute(action: TrixMacInteropAction) -> TrixMacInteropActionResult {
        switch action.name {
        case .bootstrapApprovedAccount:
            return performBootstrapApprovedAccount()
        case .sendText:
            return .failure("sendText is not supported by the macOS interop bridge yet.")
        }
    }

    private static func performBootstrapApprovedAccount() -> TrixMacInteropActionResult {
        let session: PersistedSession
        do {
            guard let loaded = try SessionStore().load() else {
                return .failure("No persisted session after UI-test bootstrap.")
            }
            session = loaded
        } catch {
            return .failure(error.localizedDescription)
        }
        guard session.deviceStatus == .active else {
            return .failure("Expected active device status for bootstrapApprovedAccount.")
        }
        let accountId = session.accountId.uuidString
        guard !accountId.isEmpty else {
            return .failure("Seeded session is missing accountId.")
        }
        return .success(accountId: accountId)
    }

    private static func emitResult(_ result: TrixMacInteropActionResult, configuration: MacUITestLaunchConfiguration) throws {
        let data = try result.encodedJSON()
        if let port = tcpPort(configuration.interopResultTCPPort) {
            let payload = data
            Task.detached(priority: .userInitiated) {
                TrixMacInteropResultTCPServer.deliverWhenClientConnects(payload: payload, port: port, timeoutSeconds: 60)
            }
        }
        if let pbName = normalizedString(configuration.interopResultPasteboardName) {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(pbName))
            pasteboard.clearContents()
            if let string = String(data: data, encoding: .utf8) {
                pasteboard.setString(string, forType: .string)
            }
        }
        if let fileName = normalizedString(configuration.interopResultOutputFileName) {
            let docs = try documentsDirectory()
            try data.write(to: docs.appendingPathComponent(fileName), options: [.atomic])
        }
    }
}

private final class TrixMacInteropTCPCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let semaphore = DispatchSemaphore(value: 0)

    func fireOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        semaphore.signal()
    }

    func wait() {
        semaphore.wait()
    }
}

private enum TrixMacInteropResultTCPServer {
    static func deliverWhenClientConnects(payload: Data, port: UInt16, timeoutSeconds: TimeInterval) {
        let queue = DispatchQueue(label: "trix.macos.interop.tcpserver")
        let gate = TrixMacInteropTCPCompletionGate()
        let framed = encodeLengthPrefixed(payload)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            gate.fireOnce()
            return
        }

        guard let listener = try? NWListener(using: .tcp, on: nwPort) else {
            gate.fireOnce()
            return
        }

        queue.asyncAfter(deadline: .now() + timeoutSeconds) {
            gate.fireOnce()
        }

        listener.newConnectionHandler = { connection in
            listener.cancel()
            let sendOnce = TrixMacInteropTCPSendOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard sendOnce.markIfFirst() else { return }
                    connection.send(content: framed, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                        gate.fireOnce()
                    })
                case .failed, .cancelled:
                    gate.fireOnce()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        listener.stateUpdateHandler = { state in
            if case .failed = state {
                gate.fireOnce()
            }
        }

        listener.start(queue: queue)
        gate.wait()
        listener.cancel()
    }

    private static func encodeLengthPrefixed(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var out = Data()
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}

private enum TrixMacInteropActionBridgeError: LocalizedError {
    case missingDocumentsDirectory
    case missingInteropAction

    var errorDescription: String? {
        switch self {
        case .missingDocumentsDirectory:
            return "Could not resolve the app Documents directory."
        case .missingInteropAction:
            return "Interop action input is missing (expected JSON env or Documents filename)."
        }
    }
}
