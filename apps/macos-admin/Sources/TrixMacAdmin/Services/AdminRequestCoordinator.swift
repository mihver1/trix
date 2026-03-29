import Foundation

/// Cancels in-flight cluster-scoped work when the active cluster changes.
actor AdminRequestCoordinator {
    private(set) var activeClusterID: UUID?
    private var cancelBoxes: [CancelBox] = []

    func setActiveCluster(_ id: UUID?) {
        guard id != activeClusterID else { return }
        activeClusterID = id
        let snapshot = cancelBoxes
        cancelBoxes.removeAll()
        for box in snapshot {
            box.fire()
        }
    }

    /// Runs `operation` while tracking it for cancellation if the active cluster changes.
    func perform<T: Sendable>(
        clusterID: UUID,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard clusterID == activeClusterID else {
            throw CancellationError()
        }
        let task = Task<T, Error> {
            try await operation()
        }
        let box = CancelBox { task.cancel() }
        cancelBoxes.append(box)
        defer {
            cancelBoxes.removeAll { ObjectIdentifier($0) == ObjectIdentifier(box) }
        }
        do {
            return try await task.value
        } catch {
            if error is CancellationError {
                throw error
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

private final class CancelBox: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func fire() {
        onCancel()
    }
}
