import XCTest
@testable import TrixMac

@MainActor
final class MacUITestAppBootstrapTests: XCTestCase {
    private final class ResetTracker {
        private let lock = NSLock()
        private var _steps: [String] = []

        func record(_ step: String) {
            lock.lock()
            defer { lock.unlock() }
            _steps.append(step)
        }

        var steps: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _steps
        }
    }

    func testPrepareForLaunchWhenUITestingDisabledReturnsNilWithoutReset() async throws {
        let tracker = ResetTracker()
        let bootstrap = MacUITestAppBootstrap(
            clearSession: { tracker.record("session") },
            removeVaultKeys: { tracker.record("vault") },
            removeWorkspacesRoot: { tracker.record("workspaces") },
            clearFixtureManifest: { tracker.record("manifest") }
        )

        let configuration = MacUITestLaunchConfiguration.make(arguments: [], environment: [:])
        let result = try await bootstrap.prepareForLaunch(configuration: configuration)

        XCTAssertNil(result)
        XCTAssertEqual(tracker.steps, [])
    }

    func testPrepareForLaunchWhenEnabledWithoutResetSkipsResetAndReturnsBaseURL() async throws {
        let tracker = ResetTracker()
        let bootstrap = MacUITestAppBootstrap(
            clearSession: { tracker.record("session") },
            removeVaultKeys: { tracker.record("vault") },
            removeWorkspacesRoot: { tracker.record("workspaces") },
            clearFixtureManifest: { tracker.record("manifest") }
        )

        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [MacUITestLaunchArgument.enableUITesting],
            environment: [MacUITestLaunchEnvironment.baseURL: "http://127.0.0.1:9999"]
        )

        let result = try await bootstrap.prepareForLaunch(configuration: configuration)

        XCTAssertEqual(result, "http://127.0.0.1:9999")
        XCTAssertEqual(tracker.steps, [])
    }

    func testPrepareForLaunchWhenEnabledWithResetRunsStepsInOrder() async throws {
        let tracker = ResetTracker()
        let bootstrap = MacUITestAppBootstrap(
            clearSession: { tracker.record("session") },
            removeVaultKeys: { tracker.record("vault") },
            removeWorkspacesRoot: { tracker.record("workspaces") },
            clearFixtureManifest: { tracker.record("manifest") }
        )

        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [
                MacUITestLaunchArgument.enableUITesting,
                MacUITestLaunchArgument.resetState,
            ],
            environment: [:]
        )

        let result = try await bootstrap.prepareForLaunch(configuration: configuration)

        XCTAssertNil(result)
        XCTAssertEqual(tracker.steps, ["session", "vault", "workspaces", "manifest"])
    }

    func testPrepareForLaunchIgnoresInvalidOwnerEditDuringVaultReset() async throws {
        let tracker = ResetTracker()
        let bootstrap = MacUITestAppBootstrap(
            clearSession: { tracker.record("session") },
            removeVaultKeys: {
                tracker.record("vault")
                throw KeychainStoreError.unhandledStatus(errSecInvalidOwnerEdit)
            },
            removeWorkspacesRoot: { tracker.record("workspaces") },
            clearFixtureManifest: { tracker.record("manifest") }
        )

        let configuration = MacUITestLaunchConfiguration.make(
            arguments: [
                MacUITestLaunchArgument.enableUITesting,
                MacUITestLaunchArgument.resetState,
            ],
            environment: [
                MacUITestLaunchEnvironment.baseURL: "http://127.0.0.1:9999",
            ]
        )

        let result = try await bootstrap.prepareForLaunch(configuration: configuration)

        XCTAssertEqual(result, "http://127.0.0.1:9999")
        XCTAssertEqual(tracker.steps, ["session", "vault", "workspaces", "manifest"])
    }

    func testResetLocalStateInvokesAllInjectedSteps() throws {
        let tracker = ResetTracker()
        let bootstrap = MacUITestAppBootstrap(
            clearSession: { tracker.record("session") },
            removeVaultKeys: { tracker.record("vault") },
            removeWorkspacesRoot: { tracker.record("workspaces") },
            clearFixtureManifest: { tracker.record("manifest") }
        )

        try bootstrap.resetLocalState()

        XCTAssertEqual(tracker.steps, ["session", "vault", "workspaces", "manifest"])
    }

    func testWorkspacesRootURLUsesApplicationSupportAndAppDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MacUITestAppBootstrapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let appDir = "test.app.support"
        let url = MacUITestAppBootstrap.workspacesRootURL(
            applicationSupportDirectory: tempRoot,
            appDirectoryName: appDir
        )

        XCTAssertEqual(
            url.path,
            tempRoot.appending(path: appDir).appending(path: "workspaces").path
        )
    }

    func testRemoveWorkspacesRootRemovesDirectoryWhenPresent() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MacUITestAppBootstrapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspaces = tempRoot.appending(path: "workspaces")
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)

        let marker = workspaces.appending(path: "marker.txt")
        try Data("x".utf8).write(to: marker)

        try MacUITestAppBootstrap.removeWorkspacesDirectoryIfPresent(at: workspaces)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaces.path))
    }

    func testWorkspaceKeychainPrefixFilterMatchesCoreStoreAccounts() {
        let matching = MacUITestWorkspaceKeychainAccountPrefixes.accountLabelsMatchingRemovalPrefixes([
            "workspace-core-store-key-v1:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "current.access-token",
            "workspace-core-store-key-v1:",
            "other",
        ])
        XCTAssertEqual(
            matching,
            [
                "workspace-core-store-key-v1:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "workspace-core-store-key-v1:",
            ]
        )
    }

    func testRemoveWorkspacesRootNoOpWhenMissing() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MacUITestAppBootstrapTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspaces = tempRoot.appending(path: "nope").appending(path: "workspaces")
        try MacUITestAppBootstrap.removeWorkspacesDirectoryIfPresent(at: workspaces)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaces.path))
    }
}
