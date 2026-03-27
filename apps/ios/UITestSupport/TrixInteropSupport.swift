import Foundation

/// Launch environment keys for the iOS interop action bridge.
enum TrixInteropLaunchEnvironment {
    /// UTF-8 JSON payload for `TrixInteropAction` (preferred for XCTest; avoids host `simctl` file staging).
    static let actionJSON = "TRIX_INTEROP_ACTION_JSON"
    /// Filename within the app `Documents` directory when JSON is not provided (host tooling may stage via `simctl`).
    static let actionPath = "TRIX_INTEROP_ACTION_PATH"
    /// Filename within the app `Documents` directory for JSON results when not using a pasteboard.
    static let resultPath = "TRIX_INTEROP_RESULT_PATH"
    /// Named pasteboard (`UIPasteboard.Name`) for UTF-8 JSON results (optional; UI-test driver uses TCP instead).
    static let resultPasteboard = "TRIX_INTEROP_RESULT_PASTEBOARD"
    /// Decimal TCP port on loopback where the **app** listens and the XCTest driver connects as client (UI-test bundles cannot bind inbound listeners on Simulator).
    static let resultTCPPort = "TRIX_INTEROP_RESULT_TCP_PORT"
}

enum TrixInteropActionName: String, Codable, Equatable {
    case sendText = "sendText"
    case bootstrapApprovedAccount = "bootstrapApprovedAccount"
}

struct TrixInteropAction: Codable, Equatable {
    let name: TrixInteropActionName
    let actor: String
    var chatAlias: String?
    var text: String?

    static func decode(_ json: String) throws -> TrixInteropAction {
        guard let data = json.data(using: .utf8) else {
            throw TrixInteropDecodingError.invalidUTF8
        }
        return try JSONDecoder().decode(TrixInteropAction.self, from: data)
    }
}

enum TrixInteropDecodingError: Error {
    case invalidUTF8
}

struct TrixInteropActionResult: Codable, Equatable {
    enum Status: String, Codable {
        case ok
        case failed
    }

    var status: Status
    var detail: String?
    var accountId: String?
    /// XCTest-persisted transcript path (driver-local; not set by the app bridge over TCP).
    var transcriptPath: String?
    /// XCTest-captured PNG paths on failure paths (driver-local).
    var screenshotPaths: [String]?

    static func success(accountId: String?, detail: String? = nil) -> TrixInteropActionResult {
        TrixInteropActionResult(
            status: .ok,
            detail: detail,
            accountId: accountId,
            transcriptPath: nil,
            screenshotPaths: nil
        )
    }

    static func failure(_ detail: String) -> TrixInteropActionResult {
        TrixInteropActionResult(
            status: .failed,
            detail: detail,
            accountId: nil,
            transcriptPath: nil,
            screenshotPaths: nil
        )
    }

    /// Copies wire payload from the app and attaches driver-local artifact paths.
    func withDriverArtifacts(transcriptPath: String, screenshotPaths: [String]) -> TrixInteropActionResult {
        TrixInteropActionResult(
            status: status,
            detail: detail,
            accountId: accountId,
            transcriptPath: transcriptPath,
            screenshotPaths: screenshotPaths.isEmpty ? nil : screenshotPaths
        )
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Preset actions for XCTest drivers (encode the shared interop JSON shape).
enum TrixInteropDriverPresetAction: Equatable {
    case bootstrapApprovedAccount
    /// Exercises app bridge rejection (`sendText` unsupported) for driver failure-artifact tests.
    case sendTextUnsupported

    func encodedJSON() throws -> Data {
        let action: TrixInteropAction
        switch self {
        case .bootstrapApprovedAccount:
            action = TrixInteropAction(
                name: .bootstrapApprovedAccount,
                actor: "ios-interop-smoke",
                chatAlias: nil,
                text: nil
            )
        case .sendTextUnsupported:
            action = TrixInteropAction(
                name: .sendText,
                actor: "ios-interop-failure-smoke",
                chatAlias: "stub",
                text: "stub"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(action)
    }
}
