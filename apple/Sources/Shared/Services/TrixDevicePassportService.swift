import Foundation

struct HTTPDevicePassportService: TrixDevicePassportService {
    private let currentDeviceURL: URL
    private let stateURL: URL
    private let approvalRequestsURL: URL
    private let directoryClaimsURL: URL
    private let noticesURL: URL

    init(baseURL: URL = TrixClientConfiguration.devicePassportAPIBaseURL) {
        self.currentDeviceURL = baseURL.appending(path: "v1/device-passport/current-device")
        self.stateURL = baseURL.appending(path: "v1/device-passport/state")
        self.approvalRequestsURL = baseURL.appending(path: "v1/device-passport/approval-requests")
        self.directoryClaimsURL = baseURL.appending(path: "v1/device-passport/directory-claims")
        self.noticesURL = baseURL.appending(path: "v1/device-passport/notices")
    }

    func upsertCurrentDevice(_ request: TrixDevicePassportCurrentDeviceRequest, session: TrixSession) async throws -> TrixDevicePassportDevice {
        let response: CurrentDeviceResponse = try await perform(
            url: currentDeviceURL,
            method: "POST",
            session: session,
            body: request
        )
        return response.device
    }

    func state(session: TrixSession, deviceID: String?) async throws -> TrixDevicePassportSnapshot {
        var request = URLRequest(url: stateURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        if let deviceID, !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Trix-Device-ID")
        }
        return try await perform(request)
    }

    func createApprovalRequest(deviceID: String, session: TrixSession) async throws -> TrixDevicePassportApprovalRequest {
        let response: ApprovalRequestResponse = try await perform(
            url: approvalRequestsURL,
            method: "POST",
            session: session,
            body: DeviceIDPayload(deviceID: deviceID)
        )
        return response.approval
    }

    func approveApprovalRequest(id: String, approverDeviceID: String, session: TrixSession) async throws -> TrixDevicePassportApproveResult {
        try await perform(
            url: approvalRequestsURL.appending(path: "\(id)/approve"),
            method: "POST",
            session: session,
            body: ApproverPayload(approverDeviceID: approverDeviceID)
        )
    }

    func declineApprovalRequest(id: String, approverDeviceID: String, session: TrixSession) async throws -> TrixDevicePassportApprovalRequest {
        let response: ApprovalRequestResponse = try await perform(
            url: approvalRequestsURL.appending(path: "\(id)/decline"),
            method: "POST",
            session: session,
            body: ApproverPayload(approverDeviceID: approverDeviceID)
        )
        return response.approval
    }

    func directoryClaims(since cursor: Int64, session: TrixSession) async throws -> TrixDevicePassportDirectoryClaimsPage {
        var components = URLComponents(url: directoryClaimsURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "since", value: "\(max(0, cursor))")
        ]
        guard let url = components?.url else {
            throw TrixClientError.devicePassportUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    func dismissNotice(targetUserID: String, severity: TrixDevicePassportNoticeSeverity, session: TrixSession) async throws {
        let normalized = targetUserID.replacingOccurrences(of: "/", with: "")
        let _: EmptyPassportResponse = try await perform(
            url: noticesURL.appending(path: "\(normalized)/dismiss"),
            method: "POST",
            session: session,
            body: NoticeDismissPayload(severity: severity)
        )
    }

    private func perform<Body: Encodable, Response: Decodable>(
        url: URL,
        method: String,
        session: TrixSession,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try Self.basicAuthorizationHeader(for: session), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TrixClientError.devicePassportUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrixClientError.devicePassportUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.error(from: data, statusCode: httpResponse.statusCode)
        }
        if Response.self == EmptyPassportResponse.self {
            return EmptyPassportResponse() as! Response
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TrixClientError.devicePassportUnavailable
        }
    }

    private static func basicAuthorizationHeader(for session: TrixSession) throws -> String {
        let userID = try normalizedXMPPUserID(session.userID)
        let password = session.accessToken
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TrixClientError.devicePassportUnavailable
        }
        guard let data = "\(userID):\(password)".data(using: .utf8) else {
            throw TrixClientError.devicePassportUnavailable
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

    private static func error(from data: Data, statusCode: Int) -> TrixClientError {
        guard let payload = try? JSONDecoder().decode(DevicePassportErrorPayload.self, from: data) else {
            return .devicePassportUnavailable
        }
        switch payload.error {
        case "unauthorized":
            return .inviteIssueUnauthorized
        case "conflict", "forbidden", "gone":
            return .devicePassportApprovalRequired
        default:
            return statusCode == 401 ? .inviteIssueUnauthorized : .devicePassportUnavailable
        }
    }
}

private struct CurrentDeviceResponse: Decodable {
    let device: TrixDevicePassportDevice
}

private struct ApprovalRequestResponse: Decodable {
    let approval: TrixDevicePassportApprovalRequest
}

private struct EmptyPassportResponse: Decodable {
}

private struct DeviceIDPayload: Encodable {
    let deviceID: String

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
    }
}

private struct ApproverPayload: Encodable {
    let approverDeviceID: String

    private enum CodingKeys: String, CodingKey {
        case approverDeviceID = "approver_device_id"
    }
}

private struct NoticeDismissPayload: Encodable {
    let severity: TrixDevicePassportNoticeSeverity
}

private struct DevicePassportErrorPayload: Decodable {
    let error: String
}

struct MockDevicePassportService: TrixDevicePassportService {
    var directoryClaimsPage: TrixDevicePassportDirectoryClaimsPage?
    var snapshot: TrixDevicePassportSnapshot = TrixDevicePassportSnapshot(
        userID: "@me:trix.selfhost.ru",
        generation: 1,
        currentDevice: TrixDevicePassportDevice(
            userID: "@me:trix.selfhost.ru",
            deviceID: "MOCK-IPHONE",
            generation: 1,
            state: .approved,
            deviceLabel: "Mock iPhone",
            platform: "ios",
            fingerprintHash: "00112233445566778899aabbccddeeff",
            appVersion: nil,
            firstSeenAtUnix: 0,
            lastSeenAtUnix: 0,
            approvedAtUnix: 0,
            approvedByDeviceID: nil,
            revokedAtUnix: nil
        ),
        currentApprovalRequest: nil,
        pendingApprovalRequests: [],
        serverStateIsTrustAuthority: false
    )

    func upsertCurrentDevice(_ request: TrixDevicePassportCurrentDeviceRequest, session: TrixSession) async throws -> TrixDevicePassportDevice {
        snapshot.currentDevice ?? TrixDevicePassportDevice(
            userID: request.userID,
            deviceID: request.omemoDeviceID,
            generation: 1,
            state: .approved,
            deviceLabel: request.deviceLabel,
            platform: request.platform,
            fingerprintHash: request.fingerprintHash,
            appVersion: request.appVersion,
            firstSeenAtUnix: 0,
            lastSeenAtUnix: 0,
            approvedAtUnix: 0,
            approvedByDeviceID: nil,
            revokedAtUnix: nil
        )
    }

    func state(session: TrixSession, deviceID: String?) async throws -> TrixDevicePassportSnapshot {
        snapshot
    }

    func createApprovalRequest(deviceID: String, session: TrixSession) async throws -> TrixDevicePassportApprovalRequest {
        TrixDevicePassportApprovalRequest(
            id: "mock-approval",
            userID: session.userID,
            deviceID: deviceID,
            generation: 1,
            challenge: "A1B2C3D4",
            status: .pending,
            createdAtUnix: 0,
            expiresAtUnix: 600,
            decidedAtUnix: nil,
            decidedByDeviceID: nil
        )
    }

    func approveApprovalRequest(id: String, approverDeviceID: String, session: TrixSession) async throws -> TrixDevicePassportApproveResult {
        let device = snapshot.currentDevice ?? TrixDevicePassportDevice(
            userID: session.userID,
            deviceID: approverDeviceID,
            generation: 1,
            state: .approved,
            deviceLabel: "Mock device",
            platform: "ios",
            fingerprintHash: "00112233445566778899aabbccddeeff",
            appVersion: nil,
            firstSeenAtUnix: 0,
            lastSeenAtUnix: 0,
            approvedAtUnix: 0,
            approvedByDeviceID: nil,
            revokedAtUnix: nil
        )
        return TrixDevicePassportApproveResult(
            device: device,
            claim: TrixDevicePassportDirectoryClaim(
                id: 1,
                userID: session.userID,
                deviceID: device.deviceID,
                generation: device.generation,
                kind: .approved,
                severity: .normal,
                fingerprintHash: device.fingerprintHash,
                proofRequired: true,
                createdAtUnix: 0,
                approvedByDeviceID: approverDeviceID
            )
        )
    }

    func declineApprovalRequest(id: String, approverDeviceID: String, session: TrixSession) async throws -> TrixDevicePassportApprovalRequest {
        try await createApprovalRequest(deviceID: "mock", session: session)
    }

    func directoryClaims(since cursor: Int64, session: TrixSession) async throws -> TrixDevicePassportDirectoryClaimsPage {
        directoryClaimsPage ?? TrixDevicePassportDirectoryClaimsPage(recipientUserID: session.userID, claims: [], nextCursor: cursor)
    }

    func dismissNotice(targetUserID: String, severity: TrixDevicePassportNoticeSeverity, session: TrixSession) async throws {
    }
}
