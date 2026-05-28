import Foundation

actor TrixAsyncOperationGate<Key: Hashable & Sendable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Error>] = [:]

    func value(
        for key: Key,
        operation: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        if let existing = tasks[key] {
            return try await existing.value
        }

        let task = Task {
            try await operation()
        }
        tasks[key] = task

        do {
            let value = try await task.value
            tasks[key] = nil
            return value
        } catch {
            tasks[key] = nil
            throw error
        }
    }

    func cancelValue(for key: Key) {
        let task = tasks.removeValue(forKey: key)
        task?.cancel()
    }
}
