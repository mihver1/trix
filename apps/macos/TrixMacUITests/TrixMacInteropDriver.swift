import Foundation
import Network
import XCTest

enum TrixMacInteropDriverError: LocalizedError {
    case invalidActionUTF8
    case tcpFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidActionUTF8:
            return "Could not encode the interop action as UTF-8."
        case .tcpFailure(let message):
            return message
        }
    }
}

private enum TrixMacInteropDriverTranscriptClock {
    static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

private struct TrixMacInteropDriverTranscript {
    let fileURL: URL
    private var lines: [String]

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trix-macos-interop-transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("interop-\(UUID().uuidString).transcript.txt")
        lines = [
            "[\(TrixMacInteropDriverTranscriptClock.stamp())] begin transcript_path=\(fileURL.path)",
        ]
    }

    var path: String {
        fileURL.path
    }

    mutating func append(_ line: String) {
        lines.append("[\(TrixMacInteropDriverTranscriptClock.stamp())] \(line)")
    }

    mutating func persist() throws {
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

enum TrixMacInteropDriver {
    @MainActor
    static func run(
        action: TrixMacInteropDriverPresetAction,
        baseURL: String
    ) async throws -> TrixMacInteropActionResult {
        try await TrixMacUITestApp.skipUnlessServerReachable()

        let actionData = try action.encodedJSON()
        guard let actionJSON = String(data: actionData, encoding: .utf8) else {
            throw TrixMacInteropDriverError.invalidActionUTF8
        }

        var transcript = try TrixMacInteropDriverTranscript()
        transcript.append("action_preset=\(String(describing: action))")
        transcript.append("actionJSON=\(actionJSON)")
        transcript.append("baseURL=\(baseURL)")

        let port = UInt16.random(in: 50_000...60_000)
        transcript.append("tcp_listen_port=\(port)")

        let app = TrixMacUITestApp.launch(
            resetState: true,
            seedScenario: .approvedAccount,
            scenarioLabel: "interop-bootstrap-smoke",
            baseURLOverride: baseURL,
            interopActionJSON: actionJSON,
            interopResultTCPPort: "\(port)"
        )
        defer { app.terminate() }

        transcript.append("post_launch app_state=\(String(describing: app.state))")

        let deadline = Date().addingTimeInterval(60)
        var lastError: Error?
        var wire: TrixMacInteropActionResult?

        while Date() < deadline {
            do {
                wire = try await receiveFramedResultClient(port: port)
                lastError = nil
                break
            } catch {
                lastError = error
                transcript.append("tcp_attempt_error=\(error.localizedDescription)")
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        if let received = wire {
            transcript.append("tcp_outcome=received")
            if let payload = try? JSONEncoder().encode(received),
               let payloadText = String(data: payload, encoding: .utf8) {
                transcript.append("wire_payload_json=\(payloadText)")
            }

            if received.status == .failed {
                let shots = captureFailureScreenshotPNGPaths()
                transcript.append("screenshot_count=\(shots.count) screenshot_paths=\(shots.joined(separator: ","))")
                transcript.append("final_outcome=app_failed")
                try transcript.persist()
                return received.withDriverArtifacts(transcriptPath: transcript.path, screenshotPaths: shots)
            }

            transcript.append("final_outcome=ok")
            try transcript.persist()
            return received.withDriverArtifacts(transcriptPath: transcript.path, screenshotPaths: [])
        }

        let shots = captureFailureScreenshotPNGPaths()
        transcript.append("tcp_outcome=timeout")
        if let lastError {
            transcript.append("last_error=\(lastError.localizedDescription)")
        }
        transcript.append("screenshot_count=\(shots.count) screenshot_paths=\(shots.joined(separator: ","))")
        transcript.append("final_outcome=driver_timeout")
        try transcript.persist()

        let detail = lastError?.localizedDescription ?? "Timed out waiting for interop TCP result."
        return TrixMacInteropActionResult.failure(detail)
            .withDriverArtifacts(transcriptPath: transcript.path, screenshotPaths: shots)
    }

    @MainActor
    private static func captureFailureScreenshotPNGPaths() -> [String] {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        guard !data.isEmpty else {
            return []
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trix-macos-interop-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("interop-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return [url.path]
        } catch {
            return []
        }
    }

    private static func receiveFramedResultClient(port: UInt16) async throws -> TrixMacInteropActionResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TrixMacInteropActionResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try Self.blockingReceiveFramed(port: port, perAttemptTimeout: 12)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func blockingReceiveFramed(port: UInt16, perAttemptTimeout: TimeInterval) throws -> TrixMacInteropActionResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TrixMacInteropDriverError.tcpFailure("Invalid TCP port.")
        }

        let queue = DispatchQueue(label: "trix.macos.interop.tcpclient")
        let gate = TrixMacInteropTCPClientGate()
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: nwPort, using: .tcp)

        queue.asyncAfter(deadline: .now() + perAttemptTimeout) {
            gate.complete(.failure(TrixMacInteropDriverError.tcpFailure("TCP receive attempt timed out.")))
            connection.cancel()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Self.readExact(connection: connection, queue: queue, needed: 4, accumulated: Data()) { result in
                    switch result {
                    case .failure(let error):
                        gate.complete(.failure(error))
                        connection.cancel()
                    case .success(let header):
                        let bodyLength = Self.bigEndianUInt32Length(header)
                        guard bodyLength >= 0, bodyLength <= 512 * 1024 else {
                            gate.complete(.failure(TrixMacInteropDriverError.tcpFailure("Invalid interop payload length.")))
                            connection.cancel()
                            return
                        }
                        Self.readExact(
                            connection: connection,
                            queue: queue,
                            needed: bodyLength,
                            accumulated: Data()
                        ) { bodyResult in
                            connection.cancel()
                            switch bodyResult {
                            case .failure(let error):
                                gate.complete(.failure(error))
                            case .success(let body):
                                do {
                                    let decoded = try JSONDecoder().decode(TrixMacInteropActionResult.self, from: body)
                                    gate.complete(.success(decoded))
                                } catch {
                                    gate.complete(.failure(error))
                                }
                            }
                        }
                    }
                }
            case .failed(let error):
                gate.complete(.failure(error))
            default:
                break
            }
        }

        connection.start(queue: queue)
        return try gate.wait()
    }

    private static func bigEndianUInt32Length(_ header: Data) -> Int {
        let b = [UInt8](header.prefix(4))
        guard b.count == 4 else { return -1 }
        let value = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        return Int(value)
    }

    private static func readExact(
        connection: NWConnection,
        queue: DispatchQueue,
        needed: Int,
        accumulated: Data,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let remaining = needed - accumulated.count
        guard remaining > 0 else {
            completion(.success(Data(accumulated.prefix(needed))))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(65536, remaining)) { data, _, isComplete, error in
            if let error {
                completion(.failure(error))
                return
            }
            var next = accumulated
            if let data, !data.isEmpty {
                next.append(data)
            }
            if next.count >= needed {
                completion(.success(Data(next.prefix(needed))))
            } else if isComplete {
                completion(.failure(TrixMacInteropDriverError.tcpFailure("Unexpected end of stream.")))
            } else {
                readExact(connection: connection, queue: queue, needed: needed, accumulated: next, completion: completion)
            }
        }
    }
}

private final class TrixMacInteropTCPClientGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<TrixMacInteropActionResult, Error>?
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(_ value: Result<TrixMacInteropActionResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        semaphore.signal()
    }

    func wait() throws -> TrixMacInteropActionResult {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw TrixMacInteropDriverError.tcpFailure("Missing TCP result.")
        }
    }
}
