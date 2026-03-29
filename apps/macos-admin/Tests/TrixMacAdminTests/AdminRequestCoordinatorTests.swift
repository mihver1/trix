import XCTest
@testable import TrixMacAdmin

final class AdminRequestCoordinatorTests: XCTestCase {
    func testPerformThrowsWhenClusterDoesNotMatchActive() async {
        let coordinator = AdminRequestCoordinator()
        let a = UUID()
        let b = UUID()
        await coordinator.setActiveCluster(a)

        do {
            _ = try await coordinator.perform(clusterID: b) {
                1
            }
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected: active is a, perform requested b
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testChangingActiveClusterCancelsInFlightPerform() async {
        let coordinator = AdminRequestCoordinator()
        let clusterA = UUID()
        let clusterB = UUID()
        await coordinator.setActiveCluster(clusterA)

        let finished = expectation(description: "perform completed")

        Task {
            do {
                _ = try await coordinator.perform(clusterID: clusterA) {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    return true
                }
                XCTFail("expected cancellation")
            } catch is CancellationError {
                // expected after switching active cluster to B
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            finished.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await coordinator.setActiveCluster(clusterB)
        await fulfillment(of: [finished], timeout: 2.0)
    }
}
