import XCTest
@testable import Trix

final class TrixAsyncOperationGateTests: XCTestCase {
    func testConcurrentRequestsForSameKeyShareOneOperation() async throws {
        let gate = TrixAsyncOperationGate<String, Int>()
        let operation = CountingOperation()

        async let first = gate.value(for: "xmpp-session") {
            try await operation.run()
        }
        async let second = gate.value(for: "xmpp-session") {
            try await operation.run()
        }
        async let third = gate.value(for: "xmpp-session") {
            try await operation.run()
        }

        let values = try await [first, second, third]

        XCTAssertEqual(values, [42, 42, 42])
        let callCount = await operation.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testFailedOperationDoesNotPoisonLaterRequests() async throws {
        let gate = TrixAsyncOperationGate<String, Int>()
        let operation = FlakyOperation()

        do {
            _ = try await gate.value(for: "xmpp-session") {
                try await operation.run()
            }
            XCTFail("Expected first operation to fail")
        } catch OperationError.failed {
        }

        let value = try await gate.value(for: "xmpp-session") {
            try await operation.run()
        }

        XCTAssertEqual(value, 7)
        let callCount = await operation.callCount
        XCTAssertEqual(callCount, 2)
    }
}

private actor CountingOperation {
    private(set) var callCount = 0

    func run() async throws -> Int {
        callCount += 1
        try await Task.sleep(for: .milliseconds(50))
        return 42
    }
}

private actor FlakyOperation {
    private(set) var callCount = 0

    func run() async throws -> Int {
        callCount += 1
        if callCount == 1 {
            throw OperationError.failed
        }
        return 7
    }
}

private enum OperationError: Error {
    case failed
}
