import XCTest
@testable import Trix

@MainActor
final class PendingApprovalStateTests: XCTestCase {
    func testPendingLinkedDeviceStartKeepsPendingApprovalState() async throws {
        let baseURL = UITestServerHarness.configuredBaseURL()
        try await UITestServerHarness.skipUnlessServerReachable(at: baseURL)
        UITestServerHarness.resetLocalAppState()
        defer { UITestServerHarness.resetLocalAppState() }

        let ownerIdentity = try createApprovedAccountIdentity(
            baseURLString: baseURL,
            label: "Pending Start Owner"
        )
        let ownerSession = try TrixCoreServerBridge.authenticate(
            baseURLString: baseURL,
            identity: ownerIdentity
        )
        let linkIntent = try TrixCoreServerBridge.createLinkIntent(
            baseURLString: baseURL,
            accessToken: ownerSession.accessToken
        )
        let pendingIdentity = try createPendingLinkedIdentity(
            linkIntentPayload: linkIntent.qrPayload,
            label: "Pending Start Linked"
        )

        try LocalDeviceIdentityStore().save(pendingIdentity)
        let restoredIdentity = try XCTUnwrap(LocalDeviceIdentityStore().load())
        XCTAssertEqual(restoredIdentity.trustState, .pendingApproval)

        let model = AppModel()
        await model.start(baseURLString: baseURL)

        XCTAssertEqual(model.localIdentity?.trustState, .pendingApproval)
        XCTAssertNil(model.dashboard)
        XCTAssertTrue(model.isAwaitingApproval)
    }

    func testUITestBootstrapPendingScenarioKeepsPendingApprovalState() async throws {
        let baseURL = UITestServerHarness.configuredBaseURL()
        try await UITestServerHarness.skipUnlessServerReachable(at: baseURL)
        UITestServerHarness.resetLocalAppState()
        defer { UITestServerHarness.resetLocalAppState() }

        let configuration = UITestLaunchConfiguration.make(
            arguments: [
                TrixUITestLaunchArgument.enableUITesting,
                TrixUITestLaunchArgument.resetState,
                TrixUITestLaunchArgument.disableAnimations,
            ],
            environment: [
                TrixUITestLaunchEnvironment.baseURL: baseURL,
                TrixUITestLaunchEnvironment.seedScenario: TrixUITestSeedScenario.pendingApproval.rawValue,
                TrixUITestLaunchEnvironment.scenarioLabel: "launch-config-pending",
            ]
        )

        let resolvedBaseURL = try await UITestAppBootstrap.prepareForLaunch(
            fallbackBaseURLString: "http://127.0.0.1:8080",
            configuration: configuration
        )
        let seededIdentity = try XCTUnwrap(LocalDeviceIdentityStore().load())
        XCTAssertEqual(seededIdentity.trustState, .pendingApproval)
        XCTAssertEqual(resolvedBaseURL, baseURL)

        let model = AppModel()
        await model.start(baseURLString: resolvedBaseURL)

        XCTAssertEqual(model.localIdentity?.trustState, .pendingApproval)
        XCTAssertNil(model.dashboard)
        XCTAssertTrue(model.isAwaitingApproval)
    }

    private func createApprovedAccountIdentity(
        baseURLString: String,
        label: String
    ) throws -> LocalDeviceIdentity {
        let suffix = uniqueSuffix()
        var form = CreateAccountForm()
        form.profileName = "\(label) \(suffix)"
        form.handle = "iospending\(suffix)"
        form.profileBio = "Pending approval test fixture"
        form.deviceDisplayName = "\(label) Device \(suffix)"

        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        let created = try TrixCoreServerBridge.createAccount(
            baseURLString: baseURLString,
            form: form,
            bootstrapMaterial: bootstrapMaterial
        )

        return bootstrapMaterial.makeLocalIdentity(
            accountId: created.accountId,
            deviceId: created.deviceId,
            accountSyncChatId: created.accountSyncChatId,
            deviceDisplayName: form.deviceDisplayName,
            platform: form.platform
        )
    }

    private func createPendingLinkedIdentity(
        linkIntentPayload: String,
        label: String
    ) throws -> LocalDeviceIdentity {
        let payload = try LinkIntentPayload.parse(linkIntentPayload)
        let bootstrapMaterial = try DeviceBootstrapMaterial.generate()
        var form = LinkExistingAccountForm()
        form.deviceDisplayName = label
        return try TrixCorePersistentBridge.completeLinkDevice(
            payload: payload,
            form: form,
            bootstrapMaterial: bootstrapMaterial
        )
    }

    private func uniqueSuffix(length: Int = 8) -> String {
        String(
            UUID().uuidString
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .prefix(length)
        )
    }
}
