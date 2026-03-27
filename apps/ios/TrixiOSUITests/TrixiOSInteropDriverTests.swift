import XCTest

@MainActor
final class TrixiOSInteropDriverTests: XCTestCase {
    func testSeededBootstrapAction() async throws {
        let result = try await TrixiOSInteropDriver.run(
            action: .bootstrapApprovedAccount,
            baseURL: TrixUITestApp.configuredBaseURL()
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertNotNil(result.accountId)
        XCTAssertFalse(try XCTUnwrap(result.accountId).isEmpty)

        let transcriptPath = try XCTUnwrap(result.transcriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptPath))
        XCTAssertNil(result.screenshotPaths)
    }

    func testUnsupportedSendTextIncludesFailureArtifacts() async throws {
        let result = try await TrixiOSInteropDriver.run(
            action: .sendTextUnsupported,
            baseURL: TrixUITestApp.configuredBaseURL()
        )

        XCTAssertEqual(result.status, .failed)
        let transcriptPath = try XCTUnwrap(result.transcriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptPath))

        let shots = try XCTUnwrap(result.screenshotPaths)
        XCTAssertEqual(shots.count, 1)
        XCTAssertTrue(shots[0].hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shots[0]))
    }
}
