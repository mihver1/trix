import XCTest
@testable import TrixMacAdmin

final class AdminAPIClientTests: XCTestCase {
    private func makeCluster() -> ClusterProfile {
        ClusterProfile(
            id: UUID(),
            displayName: "prod-eu",
            baseURL: URL(string: "https://eu.example")!,
            environmentLabel: "prod"
        )
    }

    func testOverviewRequestUsesClusterBaseURLAndBearerToken() async throws {
        let recorder = HTTPRequestRecorder()
        let client = AdminAPIClient(session: recorder.session)
        let cluster = makeCluster()

        _ = try await client.fetchOverview(cluster: cluster, accessToken: "token-123")

        XCTAssertEqual(recorder.lastRequest?.url?.absoluteString, "https://eu.example/v0/admin/overview")
        XCTAssertEqual(recorder.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
    }

    func testCreateSessionPostsCredentialsWithoutBearerToken() async throws {
        let recorder = HTTPRequestRecorder()
        let client = AdminAPIClient(session: recorder.session)
        let cluster = makeCluster()

        _ = try await client.createSession(cluster: cluster, username: "admin", password: "secret")

        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://eu.example/v0/admin/session")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(AdminAPIClientTests.requestBodyData(req))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["username"] as? String, "admin")
        XCTAssertEqual(obj["password"] as? String, "secret")
    }

    func testUpdateRegistrationSettingsPatchesWithBearerAndJSONBody() async throws {
        let recorder = HTTPRequestRecorder()
        let client = AdminAPIClient(session: recorder.session)
        let cluster = makeCluster()

        _ = try await client.updateRegistrationSettings(
            cluster: cluster,
            accessToken: "tok",
            allowPublicAccountRegistration: false
        )

        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://eu.example/v0/admin/settings/registration")
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(AdminAPIClientTests.requestBodyData(req))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["allow_public_account_registration"] as? Bool, false)
    }

    func testDisableUserPostsToDisablePathWithBearerAndReasonJSON() async throws {
        let recorder = HTTPRequestRecorder()
        let client = AdminAPIClient(session: recorder.session)
        let cluster = makeCluster()
        let accountId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

        try await client.disableUser(cluster: cluster, accessToken: "tok", accountId: accountId, reason: "policy")

        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(
            req.url?.absoluteString,
            "https://eu.example/v0/admin/users/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/disable"
        )
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(AdminAPIClientTests.requestBodyData(req))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["reason"] as? String, "policy")
    }

    func testFetchUsersEncodesQueryItemsOnListEndpoint() async throws {
        let recorder = HTTPRequestRecorder()
        let client = AdminAPIClient(session: recorder.session)
        let cluster = makeCluster()

        _ = try await client.fetchUsers(
            cluster: cluster,
            accessToken: "tok",
            query: "bo",
            status: "active",
            cursor: "c1",
            limit: 10
        )

        let req = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let url = try XCTUnwrap(req.url)
        XCTAssertEqual(url.path, "/v0/admin/users")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "bo")
        XCTAssertEqual(items.first { $0.name == "status" }?.value, "active")
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "c1")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "10")
    }

    /// URLSession often supplies `httpBodyStream` instead of `httpBody` on the request seen by tests.
    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var out = Data()
        let chunk = 4096
        var buffer = [UInt8](repeating: 0, count: chunk)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: chunk)
            if n < 0 {
                return nil
            }
            if n == 0 {
                break
            }
            out.append(buffer, count: n)
        }
        return out
    }
}

// MARK: - Test URLSession

final class HTTPRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastRequest: URLRequest?

    var lastRequest: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _lastRequest
    }

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        RecordingURLRecorder.shared = self
        return URLSession(configuration: config)
    }()
}

private enum RecordingURLRecorder {
    /// Test-only bridge from URLProtocol to the active recorder (single test at a time).
    nonisolated(unsafe) static weak var shared: HTTPRequestRecorder?
}

private final class RecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        RecordingURLRecorder.shared?.record(request)
        guard let url = request.url, let method = request.httpMethod else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        let (status, body, contentType): (Int, Data, String?) = {
            switch (method, path) {
            case ("POST", "/v0/admin/session"):
                return (200, Self.sessionResponseJSON.data(using: .utf8)!, "application/json")
            case ("PATCH", "/v0/admin/settings/registration"):
                return (200, Self.registrationSettingsJSON.data(using: .utf8)!, "application/json")
            case ("POST", _) where path.hasSuffix("/disable"):
                return (204, Data(), nil)
            case ("GET", "/v0/admin/users"):
                return (200, Self.emptyUserListJSON.data(using: .utf8)!, "application/json")
            default:
                return (200, Self.minimalOverviewJSON.data(using: .utf8)!, "application/json")
            }
        }()

        var headers: [String: String] = [:]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let sessionResponseJSON = """
    {
      "access_token": "issued-token",
      "expires_at_unix": 9999999999,
      "username": "admin"
    }
    """

    private static let registrationSettingsJSON = """
    {
      "allow_public_account_registration": false
    }
    """

    private static let emptyUserListJSON = """
    {
      "users": [],
      "next_cursor": null
    }
    """

    private static let minimalOverviewJSON = """
    {
      "status": "ok",
      "service": "trix",
      "version": "0.0.0",
      "git_sha": null,
      "health_status": "ok",
      "uptime_ms": 0,
      "allow_public_account_registration": true,
      "user_count": 0,
      "disabled_user_count": 0,
      "admin_username": "admin",
      "admin_session_expires_at_unix": 9999999999
    }
    """
}

extension HTTPRequestRecorder {
    fileprivate func record(_ request: URLRequest) {
        lock.lock()
        _lastRequest = request
        lock.unlock()
    }
}
