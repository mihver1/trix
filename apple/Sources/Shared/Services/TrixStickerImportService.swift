import Foundation

struct TrixTelegramStickerPackImport: Equatable, Sendable {
    let packID: String
    let title: String
    let source: TrixStickerSource
    let stickers: [TrixTelegramStickerImportItem]
    let unsupportedStickerCount: Int
}

struct TrixTelegramStickerImportItem: Identifiable, Equatable, Sendable {
    let id: String
    let packID: String
    let emoji: String?
    let filename: String
    let mimeType: String
    let sizeBytes: Int?
    let imageDimensions: TrixAttachmentImageDimensions?
    let source: TrixStickerSource
    let fileToken: String
}

struct TrixTelegramStickerFileDownload: Equatable, Sendable {
    let filename: String
    let mimeType: String
    let data: Data
}

enum TrixTelegramStickerPackReference {
    static func normalizedName(from value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TrixClientError.stickerPackUnavailable
        }

        let candidate: String
        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           ["t.me", "telegram.me"].contains(host) {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count >= 2,
                  parts[0].caseInsensitiveCompare("addstickers") == .orderedSame else {
                throw TrixClientError.stickerPackUnavailable
            }
            candidate = parts[1]
        } else if URL(string: trimmed)?.host != nil {
            throw TrixClientError.stickerPackUnavailable
        } else if trimmed.range(of: #"^(t\.me|telegram\.me)/addstickers/"#, options: [.regularExpression, .caseInsensitive]) != nil {
            candidate = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .components(separatedBy: "/")
                .last ?? trimmed
        } else {
            candidate = trimmed
        }

        let name = candidate
            .components(separatedBy: CharacterSet(charactersIn: "?#"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard name.range(of: #"^[A-Za-z0-9_]{1,128}$"#, options: .regularExpression) != nil else {
            throw TrixClientError.stickerPackUnavailable
        }
        return name
    }
}

struct HTTPStickerImportService: TrixStickerImportService {
    private let packURL: URL
    private let fileURL: URL

    init(baseURL: URL = TrixClientConfiguration.registrationAPIBaseURL) {
        self.packURL = baseURL.appending(path: "v1/stickers/telegram/packs")
        self.fileURL = baseURL.appending(path: "v1/stickers/telegram/file")
    }

    func resolveTelegramStickerPack(_ reference: String, session: TrixSession) async throws -> TrixTelegramStickerPackImport {
        let normalizedName = try TrixTelegramStickerPackReference.normalizedName(from: reference)
        let payload = TelegramPackRequest(packURL: "https://t.me/addstickers/\(normalizedName)")

        var request = URLRequest(url: packURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TrixClientError.stickerImportUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.stickerImportUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.importError(from: data, statusCode: httpResponse.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(TelegramPackResponse.self, from: data)
            let items = decoded.pack.stickers.map { sticker in
                TrixTelegramStickerImportItem(
                    id: sticker.id,
                    packID: sticker.packID,
                    emoji: sticker.emoji,
                    filename: sticker.filename,
                    mimeType: sticker.mimeType,
                    sizeBytes: sticker.sizeBytes,
                    imageDimensions: Self.imageDimensions(width: sticker.width, height: sticker.height),
                    source: sticker.source,
                    fileToken: sticker.fileToken
                )
            }
            return TrixTelegramStickerPackImport(
                packID: decoded.pack.id,
                title: decoded.pack.title,
                source: decoded.pack.source,
                stickers: items,
                unsupportedStickerCount: decoded.unsupportedCount
            )
        } catch {
            throw TrixClientError.stickerImportUnavailable
        }
    }

    func downloadTelegramStickerFile(_ sticker: TrixTelegramStickerImportItem, session: TrixSession) async throws -> TrixTelegramStickerFileDownload {
        let payload = TelegramFileRequest(fileToken: sticker.fileToken)

        var request = URLRequest(url: fileURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TrixClientError.stickerFileUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              !data.isEmpty else {
            throw TrixClientError.stickerFileUnavailable
        }

        let filename = httpResponse.value(forHTTPHeaderField: "X-Trix-Sticker-Filename") ?? sticker.filename
        let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";")
            .first
            .map(String.init) ?? sticker.mimeType
        return TrixTelegramStickerFileDownload(
            filename: filename,
            mimeType: mimeType,
            data: data
        )
    }

    private static func basicAuthorizationHeader(for session: TrixSession) throws -> String {
        let userID = try normalizedXMPPUserID(session.userID)
        let password = session.accessToken
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.stickerImportUnavailable
        }

        let credentials = "\(userID):\(password)"
        guard let data = credentials.data(using: .utf8) else {
            throw TrixClientError.stickerImportUnavailable
        }
        return "Basic \(data.base64EncodedString())"
    }

    private static func normalizedXMPPUserID(_ userID: String) throws -> String {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("@"), let separator = trimmed.firstIndex(of: ":") {
            let localpart = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator])
            let server = String(trimmed[trimmed.index(after: separator)...])
            guard !localpart.isEmpty, server == TrixClientConfiguration.serverName else {
                throw TrixClientError.invalidTrixUserID
            }
            return "\(localpart)@\(server)"
        }

        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localpart = parts.first,
              let domain = parts.last,
              !localpart.isEmpty,
              domain == TrixClientConfiguration.serverName,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw TrixClientError.invalidTrixUserID
        }
        return trimmed
    }

    private static func importError(from data: Data, statusCode: Int) -> TrixClientError {
        guard let error = try? JSONDecoder().decode(StickerErrorPayload.self, from: data) else {
            return statusCode == 401 ? .inviteIssueUnauthorized : .stickerImportUnavailable
        }
        switch error.error {
        case "invalid_sticker_pack":
            return .stickerPackUnavailable
        case "telegram_import_unavailable":
            return .stickerImportUnavailable
        case "unauthorized":
            return .inviteIssueUnauthorized
        default:
            return .stickerImportUnavailable
        }
    }

    private static func imageDimensions(width: Int?, height: Int?) -> TrixAttachmentImageDimensions? {
        guard let width, let height, width > 0, height > 0 else {
            return nil
        }
        return TrixAttachmentImageDimensions(width: UInt64(width), height: UInt64(height))
    }
}

private struct TelegramPackRequest: Encodable {
    let packURL: String

    private enum CodingKeys: String, CodingKey {
        case packURL = "pack_url"
    }
}

private struct TelegramFileRequest: Encodable {
    let fileToken: String

    private enum CodingKeys: String, CodingKey {
        case fileToken = "file_token"
    }
}

private struct TelegramPackResponse: Decodable {
    let pack: TelegramPackPayload
    let unsupportedCount: Int

    private enum CodingKeys: String, CodingKey {
        case pack
        case unsupportedCount = "unsupported_count"
    }
}

private struct TelegramPackPayload: Decodable {
    let id: String
    let title: String
    let source: TrixStickerSource
    let stickers: [TelegramStickerPayload]
}

private struct TelegramStickerPayload: Decodable {
    let id: String
    let packID: String
    let emoji: String?
    let filename: String
    let mimeType: String
    let width: Int?
    let height: Int?
    let sizeBytes: Int?
    let fileToken: String
    let source: TrixStickerSource

    private enum CodingKeys: String, CodingKey {
        case id
        case packID = "pack_id"
        case emoji
        case filename
        case mimeType = "mime_type"
        case width
        case height
        case sizeBytes = "size_bytes"
        case fileToken = "file_token"
        case source
    }
}

private struct StickerErrorPayload: Decodable {
    let error: String
}
