import XCTest
@testable import Trix

final class TrixFeatureFlagTests: XCTestCase {
    func testDecodesServerSnapshot() throws {
        let data = Data(
            """
            {
              "version": 2,
              "updated_at_unix": 1780000000,
              "flags": [
                {
                  "key": "client.calls.encrypted_media",
                  "enabled": true,
                  "rollout_percentage": 25,
                  "client_visible": true,
                  "description": "Calls gate",
                  "updated_at_unix": 1780000000
                }
              ]
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(TrixFeatureFlagSnapshot.self, from: data)

        XCTAssertEqual(snapshot.version, 2)
        XCTAssertEqual(snapshot.flags.first?.key, "client.calls.encrypted_media")
        XCTAssertEqual(snapshot.flags.first?.rolloutPercentage, 25)
    }

    func testEvaluatorHonorsDisabledAndFullRollout() {
        let snapshot = TrixFeatureFlagSnapshot(
            version: 1,
            updatedAtUnix: 0,
            flags: [
                TrixFeatureFlag(
                    key: "client.on",
                    enabled: true,
                    rolloutPercentage: 100,
                    clientVisible: true,
                    description: "",
                    updatedAtUnix: 0
                ),
                TrixFeatureFlag(
                    key: "client.off",
                    enabled: false,
                    rolloutPercentage: 100,
                    clientVisible: true,
                    description: "",
                    updatedAtUnix: 0
                ),
            ]
        )
        let evaluator = TrixFeatureFlagEvaluator(snapshot: snapshot)
        let context = TrixFeatureFlagContext(stableID: "alice@trix.selfhost.ru")

        XCTAssertTrue(evaluator.isEnabled("client.on", context: context))
        XCTAssertFalse(evaluator.isEnabled("client.off", context: context))
        XCTAssertFalse(evaluator.isEnabled("client.missing", context: context))
    }

    func testEvaluatorUsesStableRolloutBuckets() {
        let snapshot = TrixFeatureFlagSnapshot(
            version: 1,
            updatedAtUnix: 0,
            flags: [
                TrixFeatureFlag(
                    key: "client.partial",
                    enabled: true,
                    rolloutPercentage: 50,
                    clientVisible: true,
                    description: "",
                    updatedAtUnix: 0
                ),
            ]
        )
        let evaluator = TrixFeatureFlagEvaluator(snapshot: snapshot)
        let context = TrixFeatureFlagContext(stableID: "Alice@Trix.Selfhost.Ru")

        XCTAssertEqual(
            evaluator.isEnabled("client.partial", context: context),
            evaluator.isEnabled("client.partial", context: context)
        )
    }
}
