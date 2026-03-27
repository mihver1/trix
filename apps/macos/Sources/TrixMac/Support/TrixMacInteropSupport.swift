import Foundation

/// Launch environment keys for the macOS interop action bridge (aligned with iOS `TRIX_INTEROP_*` for cross-client tooling).
enum TrixMacInteropLaunchEnvironment {
    static let actionJSON = "TRIX_INTEROP_ACTION_JSON"
    static let actionPath = "TRIX_INTEROP_ACTION_PATH"
    static let resultPath = "TRIX_INTEROP_RESULT_PATH"
    static let resultPasteboard = "TRIX_INTEROP_RESULT_PASTEBOARD"
    static let resultTCPPort = "TRIX_INTEROP_RESULT_TCP_PORT"
}

enum TrixMacInteropActionName: String, Codable, Equatable {
    case sendText = "sendText"
    case bootstrapApprovedAccount = "bootstrapApprovedAccount"
}

struct TrixMacInteropAction: Codable, Equatable {
    let name: TrixMacInteropActionName
    let actor: String
    var chatAlias: String?
    var text: String?

    static func decode(_ json: String) throws -> TrixMacInteropAction {
        guard let data = json.data(using: .utf8) else {
            throw TrixMacInteropDecodingError.invalidUTF8
        }
        return try JSONDecoder().decode(TrixMacInteropAction.self, from: data)
    }
}

enum TrixMacInteropDecodingError: Error {
    case invalidUTF8
}

struct TrixMacInteropActionResult: Codable, Equatable {
    enum Status: String, Codable {
        case ok
        case failed
    }

    var status: Status
    var detail: String?
    var accountId: String?
    var transcriptPath: String?
    var screenshotPaths: [String]?

    static func success(accountId: String?, detail: String? = nil) -> TrixMacInteropActionResult {
        TrixMacInteropActionResult(
            status: .ok,
            detail: detail,
            accountId: accountId,
            transcriptPath: nil,
            screenshotPaths: nil
        )
    }

    static func failure(_ detail: String) -> TrixMacInteropActionResult {
        TrixMacInteropActionResult(
            status: .failed,
            detail: detail,
            accountId: nil,
            transcriptPath: nil,
            screenshotPaths: nil
        )
    }

    func withDriverArtifacts(transcriptPath: String, screenshotPaths: [String]) -> TrixMacInteropActionResult {
        TrixMacInteropActionResult(
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

enum TrixMacInteropDriverPresetAction: Equatable {
    case bootstrapApprovedAccount
    case sendTextUnsupported

    func encodedJSON() throws -> Data {
        let action: TrixMacInteropAction
        switch self {
        case .bootstrapApprovedAccount:
            action = TrixMacInteropAction(
                name: .bootstrapApprovedAccount,
                actor: "macos-interop-smoke",
                chatAlias: nil,
                text: nil
            )
        case .sendTextUnsupported:
            action = TrixMacInteropAction(
                name: .sendText,
                actor: "macos-interop-failure-smoke",
                chatAlias: "stub",
                text: "stub"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(action)
    }
}
