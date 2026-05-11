import Foundation

struct TrixInviteIssueRequest: Equatable, Sendable {
    let localpart: String
    let displayName: String
    let ttlSeconds: Int

    init(localpart: String, displayName: String, ttlSeconds: Int) {
        self.localpart = localpart.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ttlSeconds = ttlSeconds
    }
}

struct TrixIssuedInvite: Codable, Equatable, Sendable {
    let inviteCode: String
    let localpart: String?
    let displayName: String?
    let expiresAt: String

    var reservedUserID: String? {
        guard let localpart, !localpart.isEmpty else {
            return nil
        }

        return "\(localpart)@\(TrixClientConfiguration.serverName)"
    }

    private enum CodingKeys: String, CodingKey {
        case inviteCode = "invite_code"
        case localpart
        case displayName = "display_name"
        case expiresAt = "expires_at"
    }
}

struct TrixInviteRegistrationRequest: Equatable, Sendable {
    let inviteCode: String
    let localpart: String
    let password: String
    let displayName: String

    init(inviteCode: String, localpart: String, password: String, displayName: String) {
        self.inviteCode = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localpart = localpart.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TrixInviteRegistrationResult: Codable, Equatable, Sendable {
    let userID: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case displayName = "display_name"
    }
}

struct TrixPasswordChangeRequest: Equatable, Sendable {
    let currentPassword: String
    let newPassword: String

    init(currentPassword: String, newPassword: String) {
        self.currentPassword = currentPassword
        self.newPassword = newPassword
    }
}

struct TrixPasswordChangeResult: Codable, Equatable, Sendable {
    let userID: String
    let changedAt: String

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case changedAt = "changed_at"
    }
}

struct HTTPInviteRegistrationService: TrixRegistrationService {
    private let issueURL: URL
    private let passwordURL: URL
    private let redeemURL: URL

    init(baseURL: URL = TrixClientConfiguration.registrationAPIBaseURL) {
        self.issueURL = baseURL.appending(path: "v1/invites")
        self.passwordURL = baseURL.appending(path: "v1/account/password")
        self.redeemURL = baseURL.appending(path: "v1/registration/redeem")
    }

    func issueInvite(_ request: TrixInviteIssueRequest, session: TrixSession) async throws -> TrixIssuedInvite {
        let payload = InviteIssuePayload(
            localpart: request.localpart.isEmpty ? nil : request.localpart,
            displayName: request.displayName.isEmpty ? nil : request.displayName,
            ttlSeconds: request.ttlSeconds
        )

        var urlRequest = URLRequest(url: issueURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TrixClientError.inviteIssueUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.inviteIssueUnavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.inviteIssueError(from: data)
        }

        do {
            return try JSONDecoder().decode(TrixIssuedInvite.self, from: data)
        } catch {
            throw TrixClientError.inviteIssueUnavailable
        }
    }

    func changePassword(_ request: TrixPasswordChangeRequest, session: TrixSession) async throws -> TrixPasswordChangeResult {
        let payload = PasswordChangePayload(newPassword: request.newPassword)

        var urlRequest = URLRequest(url: passwordURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(
            try Self.basicAuthorizationHeader(
                for: session,
                passwordOverride: request.currentPassword,
                unavailableError: .inviteIssueUnauthorized
            ),
            forHTTPHeaderField: "Authorization"
        )
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TrixClientError.passwordChangeUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.passwordChangeUnavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.passwordChangeError(from: data)
        }

        do {
            return try JSONDecoder().decode(TrixPasswordChangeResult.self, from: data)
        } catch {
            throw TrixClientError.passwordChangeUnavailable
        }
    }

    func redeemInvite(_ request: TrixInviteRegistrationRequest) async throws -> TrixInviteRegistrationResult {
        let payload = InviteRedeemPayload(
            inviteCode: request.inviteCode,
            localpart: request.localpart,
            password: request.password,
            displayName: request.displayName.isEmpty ? nil : request.displayName
        )

        var urlRequest = URLRequest(url: redeemURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TrixClientError.registrationUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.registrationUnavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.registrationError(from: data)
        }

        do {
            return try JSONDecoder().decode(TrixInviteRegistrationResult.self, from: data)
        } catch {
            throw TrixClientError.registrationUnavailable
        }
    }

    private static func basicAuthorizationHeader(
        for session: TrixSession,
        passwordOverride: String? = nil,
        unavailableError: TrixClientError = .inviteIssueUnavailable
    ) throws -> String {
        let userID = try normalizedXMPPUserID(session.userID)
        let password = passwordOverride ?? session.accessToken
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw unavailableError
        }

        let credentials = "\(userID):\(password)"
        guard let data = credentials.data(using: .utf8) else {
            throw unavailableError
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

    private static func inviteIssueError(from data: Data) -> TrixClientError {
        guard let error = try? JSONDecoder().decode(InviteErrorPayload.self, from: data) else {
            return .inviteIssueUnavailable
        }

        switch error.error {
        case "invalid_localpart",
             "invalid_ttl",
             "missing_field":
            return .invalidRegistrationInvite
        case "unauthorized":
            return .inviteIssueUnauthorized
        default:
            return .inviteIssueUnavailable
        }
    }

    private static func passwordChangeError(from data: Data) -> TrixClientError {
        guard let error = try? JSONDecoder().decode(InviteErrorPayload.self, from: data) else {
            return .passwordChangeUnavailable
        }

        switch error.error {
        case "weak_password":
            return .registrationPasswordTooWeak
        case "unauthorized":
            return .inviteIssueUnauthorized
        default:
            return .passwordChangeUnavailable
        }
    }

    private static func registrationError(from data: Data) -> TrixClientError {
        guard let error = try? JSONDecoder().decode(InviteErrorPayload.self, from: data) else {
            return .registrationUnavailable
        }

        switch error.error {
        case "weak_password":
            return .registrationPasswordTooWeak
        case "invite_not_found",
             "invite_used",
             "invite_in_progress",
             "invite_expired",
             "invalid_invite",
             "localpart_reserved",
             "invalid_localpart",
             "missing_field":
            return .invalidRegistrationInvite
        default:
            return .registrationUnavailable
        }
    }
}

#if DEBUG
struct MockInviteRegistrationService: TrixRegistrationService {
    func issueInvite(_ request: TrixInviteIssueRequest, session: TrixSession) async throws -> TrixIssuedInvite {
        guard !session.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.inviteIssueUnauthorized
        }

        let localpart = request.localpart.isEmpty ? nil : request.localpart.lowercased()
        return TrixIssuedInvite(
            inviteCode: "mock-\(UUID().uuidString.prefix(8))-\(UUID().uuidString.prefix(8))",
            localpart: localpart,
            displayName: request.displayName.isEmpty ? nil : request.displayName,
            expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(request.ttlSeconds)))
        )
    }

    func redeemInvite(_ request: TrixInviteRegistrationRequest) async throws -> TrixInviteRegistrationResult {
        guard !request.inviteCode.isEmpty,
              !request.localpart.isEmpty else {
            throw TrixClientError.invalidRegistrationInvite
        }

        guard request.password.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else {
            throw TrixClientError.registrationPasswordTooWeak
        }

        return TrixInviteRegistrationResult(
            userID: "@\(request.localpart.lowercased()):\(TrixClientConfiguration.serverName)",
            displayName: request.displayName.isEmpty ? nil : request.displayName
        )
    }

    func changePassword(_ request: TrixPasswordChangeRequest, session: TrixSession) async throws -> TrixPasswordChangeResult {
        guard !session.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.inviteIssueUnauthorized
        }

        guard !request.currentPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.inviteIssueUnauthorized
        }

        guard request.newPassword.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else {
            throw TrixClientError.registrationPasswordTooWeak
        }

        return TrixPasswordChangeResult(
            userID: session.userID,
            changedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}
#endif

private struct InviteIssuePayload: Encodable {
    let localpart: String?
    let displayName: String?
    let ttlSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case localpart
        case displayName = "display_name"
        case ttlSeconds = "ttl_seconds"
    }
}

private struct InviteRedeemPayload: Encodable {
    let inviteCode: String
    let localpart: String
    let password: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case inviteCode = "invite_code"
        case localpart
        case password
        case displayName = "display_name"
    }
}

private struct PasswordChangePayload: Encodable {
    let newPassword: String

    private enum CodingKeys: String, CodingKey {
        case newPassword = "new_password"
    }
}

private struct InviteErrorPayload: Decodable {
    let error: String
    let message: String?
}
