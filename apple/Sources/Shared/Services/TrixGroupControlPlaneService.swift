import Foundation

protocol TrixGroupControlPlaneService: Sendable {
    func leaveGroup(roomID: String, session: TrixSession) async throws
}

struct TrixGroupLeaveOperation {
    private let controlPlaneLeave: (String, TrixSession) async throws -> Void
    private let localMUCLeave: () async throws -> Void

    init(
        controlPlaneLeave: @escaping (String, TrixSession) async throws -> Void,
        localMUCLeave: @escaping () async throws -> Void
    ) {
        self.controlPlaneLeave = controlPlaneLeave
        self.localMUCLeave = localMUCLeave
    }

    func leave(roomID: String, session: TrixSession) async throws {
        do {
            try await controlPlaneLeave(roomID, session)
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.groupLeaveUnavailable
        }

        try? await localMUCLeave()
    }
}

struct HTTPGroupControlPlaneService: TrixGroupControlPlaneService {
    private let leaveGroupURL: URL

    init(baseURL: URL = TrixClientConfiguration.registrationAPIBaseURL) {
        self.leaveGroupURL = baseURL.appending(path: "v1/groups/leave")
    }

    func leaveGroup(roomID: String, session: TrixSession) async throws {
        var request = URLRequest(url: leaveGroupURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(TrixGroupLeavePayload(roomID: roomID))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TrixClientError.groupLeaveUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.groupLeaveUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TrixClientError.groupLeaveUnavailable
        }

        do {
            let decoded = try JSONDecoder().decode(TrixGroupLeaveResponse.self, from: data)
            guard decoded.left,
                  decoded.roomID.caseInsensitiveCompare(roomID) == .orderedSame else {
                throw TrixClientError.groupLeaveUnavailable
            }
        } catch let error as TrixClientError {
            throw error
        } catch {
            throw TrixClientError.groupLeaveUnavailable
        }
    }

    private static func basicAuthorizationHeader(for session: TrixSession) throws -> String {
        let userID = try normalizedXMPPUserID(session.userID)
        let password = session.accessToken
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.groupLeaveUnavailable
        }

        let credentials = "\(userID):\(password)"
        guard let data = credentials.data(using: .utf8) else {
            throw TrixClientError.groupLeaveUnavailable
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
}

private struct TrixGroupLeavePayload: Encodable, Sendable {
    let roomID: String

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
    }
}

private struct TrixGroupLeaveResponse: Decodable, Sendable {
    let roomID: String
    let left: Bool

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case left
    }
}
