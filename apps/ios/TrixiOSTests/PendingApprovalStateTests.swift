import XCTest
@testable import Trix

@MainActor
final class PendingApprovalStateTests: XCTestCase {
    func testPendingLinkedDeviceStartKeepsPendingApprovalState() async throws {
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)
        resetLocalAppState()
        defer { resetLocalAppState() }

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
        let baseURL = configuredBaseURL()
        try await skipUnlessServerReachable(at: baseURL)
        resetLocalAppState()
        defer { resetLocalAppState() }

        let configuration = UITestLaunchConfiguration(
            isEnabled: true,
            resetLocalState: true,
            disableAnimations: true,
            baseURLOverride: baseURL,
            seedScenario: .pendingApproval,
            conversationScenario: nil,
            scenarioLabel: "launch-config-pending",
            interopActionJSON: nil,
            interopActionInputFileName: nil,
            interopResultOutputFileName: nil,
            interopResultPasteboardName: nil,
            interopResultTCPPort: nil
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

    private func configuredBaseURL() -> String {
        ProcessInfo.processInfo.environment["TRIX_IOS_SERVER_SMOKE_BASE_URL"]?
            .trix_trimmedOrNil() ?? "http://localhost:8080"
    }

    private func skipUnlessServerReachable(at baseURL: String) async throws {
        let healthURL = try XCTUnwrap(URL(string: "\(baseURL)/v0/system/health"))

        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw XCTSkip(
                    "Pending approval state test skipped because \(healthURL.absoluteString) returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip(
                "Pending approval state test skipped because \(healthURL.absoluteString) is not reachable: \(error.localizedDescription)"
            )
        }
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

    private func resetLocalAppState() {
        if let identity = try? LocalDeviceIdentityStore().load() {
            try? TrixCorePersistentBridge.deletePersistentState(identity: identity)
        }
        try? LocalDeviceIdentityStore().delete()

        guard let appSupportRoot = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        let trixDirectory = appSupportRoot.appendingPathComponent("TrixiOS", isDirectory: true)
        try? FileManager.default.removeItem(
            at: trixDirectory.appendingPathComponent("CoreState", isDirectory: true)
        )
        try? FileManager.default.removeItem(
            at: trixDirectory.appendingPathComponent("SimulatorKeychainFallback", isDirectory: true)
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
