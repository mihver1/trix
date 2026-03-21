import Combine
import Foundation

struct SafeDiagnosticLogEntry: Identifiable, Equatable {
    let id: String
    let line: String
}

@MainActor
final class SafeDiagnosticLogStore: ObservableObject {
    static let shared = SafeDiagnosticLogStore(
        appDirectoryName: AppIdentity.applicationSupportDirectoryName
    )

    @Published private(set) var entries: [SafeDiagnosticLogEntry] = []

    let activeLogURL: URL

    private let rotatedLogURL: URL
    private let limit = 160

    init(appDirectoryName: String) {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let logDirectory = appSupport
            .appending(path: appDirectoryName)
            .appending(path: "logs")
        self.activeLogURL = logDirectory.appending(path: "client.log")
        self.rotatedLogURL = logDirectory.appending(path: "client.log.1")

        reload()
    }

    func info(_ category: String, _ message: String) {
        append(level: "INFO", category: category, message: message, error: nil)
    }

    func warn(_ category: String, _ message: String, error: Error? = nil) {
        append(level: "WARN", category: category, message: message, error: error)
    }

    func error(_ category: String, _ message: String, error: Error? = nil) {
        append(level: "ERROR", category: category, message: message, error: error)
    }

    func reload() {
        entries = loadRecentEntries(limit: limit)
    }

    func clear() {
        try? FileManager.default.removeItem(at: activeLogURL)
        try? FileManager.default.removeItem(at: rotatedLogURL)
        entries = []
    }

    private func append(
        level: String,
        category: String,
        message: String,
        error: Error?
    ) {
        do {
            let logDirectory = activeLogURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            rotateIfNeeded()

            var line = "\(timestamp()) \(level.padding(toLength: 5, withPad: " ", startingAt: 0)) \(category.prefix(24)) | \(message)"
            if let error {
                line += " | \(safeErrorDescription(error))"
            }
            line += "\n"

            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: activeLogURL.path) {
                    let handle = try FileHandle(forWritingTo: activeLogURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: activeLogURL, options: .atomic)
                }
            }
        } catch {
            return
        }

        reload()
    }

    private func rotateIfNeeded() {
        guard FileManager.default.fileExists(atPath: activeLogURL.path) else {
            return
        }

        let fileSize = (try? activeLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize >= 256 * 1024 else {
            return
        }

        try? FileManager.default.removeItem(at: rotatedLogURL)
        try? FileManager.default.moveItem(at: activeLogURL, to: rotatedLogURL)
    }

    private func loadRecentEntries(limit: Int) -> [SafeDiagnosticLogEntry] {
        let lines = [rotatedLogURL, activeLogURL]
            .compactMap(readLines(from:))
            .flatMap { $0 }
            .suffix(limit)

        return lines.enumerated().map { index, line in
            SafeDiagnosticLogEntry(
                id: "\(index)-\(line.hashValue)",
                line: line
            )
        }
    }

    private func readLines(from url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func timestamp() -> String {
        Self.timestampFormatter.string(from: Date())
    }

    private func safeErrorDescription(_ error: Error) -> String {
        if let apiError = error as? TrixAPIError {
            switch apiError {
            case .invalidResponse:
                return "TrixAPIError.invalidResponse"
            case .invalidPayload:
                return "TrixAPIError.invalidPayload"
            case let .server(code, _, statusCode):
                return "TrixAPIError.server status=\(statusCode) code=\(safeToken(code))"
            case let .transport(inner):
                return "TrixAPIError.transport cause=\(String(reflecting: type(of: inner)))"
            }
        }

        let nsError = error as NSError
        var components = [String(reflecting: type(of: error))]

        if !nsError.domain.isEmpty {
            components.append("domain=\(safeToken(nsError.domain))")
        }
        components.append("code=\(nsError.code)")

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append("underlying=\(safeToken(underlying.domain))#\(underlying.code)")
        }

        return components.joined(separator: " ")
    }

    private func safeToken(_ value: String) -> String {
        let filtered = value.filter { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
        }
        if filtered.isEmpty {
            return "redacted"
        }

        return String(filtered.prefix(48))
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
