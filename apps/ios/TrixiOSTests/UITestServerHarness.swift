import XCTest
@testable import Trix

enum UITestServerHarness {
    private static let uiBaseURLEnvironmentKey = "TRIX_IOS_UI_TEST_BASE_URL"
    private static let serverSmokeBaseURLEnvironmentKey = "TRIX_IOS_SERVER_SMOKE_BASE_URL"

    static func configuredBaseURL() -> String {
        ProcessInfo.processInfo.environment[uiBaseURLEnvironmentKey]?
            .trix_trimmedOrNil()
            ?? ProcessInfo.processInfo.environment[serverSmokeBaseURLEnvironmentKey]?
                .trix_trimmedOrNil()
            ?? "http://localhost:8080"
    }

    static func skipUnlessServerReachable(at baseURL: String) async throws {
        let healthURL = try XCTUnwrap(URL(string: "\(baseURL)/v0/system/health"))

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw XCTSkip(
                    "iOS unit smoke skipped because \(healthURL.absoluteString) returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip(
                "iOS unit smoke skipped because \(healthURL.absoluteString) is not reachable: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    static func resetLocalAppState() {
        if let identity = try? LocalDeviceIdentityStore().load() {
            try? TrixCorePersistentBridge.deletePersistentState(identity: identity)
        }
        try? UITestAppBootstrap.resetLocalStateForTesting()
    }
}
