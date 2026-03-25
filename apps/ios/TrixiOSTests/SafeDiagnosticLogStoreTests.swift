import Foundation
import XCTest
@testable import Trix

@MainActor
final class SafeDiagnosticLogStoreTests: XCTestCase {
    func testInfoAppendsReadableEntry() throws {
        let store = makeStore()

        store.info("bootstrap", "ready")

        let line = try XCTUnwrap(store.entries.last?.line)
        XCTAssertTrue(line.contains("INFO"))
        XCTAssertTrue(line.contains("bootstrap"))
        XCTAssertTrue(line.contains("ready"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.activeLogURL.path))
    }

    func testAPIHttpErrorsAreRedactedToStatusCode() throws {
        let store = makeStore()

        store.error(
            "network",
            "request failed",
            error: APIError.http(statusCode: 401, message: "Bearer secret-token")
        )

        let line = try XCTUnwrap(store.entries.last?.line)
        XCTAssertTrue(line.contains("APIError.http status=401"))
        XCTAssertFalse(line.contains("secret-token"))
        XCTAssertFalse(line.contains("Bearer"))
    }

    func testLargeActiveLogRotatesBeforeAppendingNewEntry() throws {
        let store = makeStore()
        let logDirectory = store.activeLogURL.deletingLastPathComponent()
        let rotatedLogURL = logDirectory.appendingPathComponent("client.log.1")

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let oversizedPayload = Data(repeating: 0x61, count: 256 * 1024)
        try oversizedPayload.write(to: store.activeLogURL, options: .atomic)

        store.info("rotation", "fresh line")

        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedLogURL.path))
        let activeContents = try String(contentsOf: store.activeLogURL, encoding: .utf8)
        XCTAssertTrue(activeContents.contains("fresh line"))
        let rotatedSize = try XCTUnwrap(
            rotatedLogURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThanOrEqual(rotatedSize, 256 * 1024)
    }

    private func makeStore() -> SafeDiagnosticLogStore {
        let store = SafeDiagnosticLogStore(appDirectoryName: "TrixiOSTests-\(UUID().uuidString)")
        store.clear()

        addTeardownBlock {
            let appDirectory = store.activeLogURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            try? FileManager.default.removeItem(at: appDirectory)
        }

        return store
    }
}
