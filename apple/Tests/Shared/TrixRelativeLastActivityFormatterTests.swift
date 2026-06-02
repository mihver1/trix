import Foundation
import XCTest
@testable import Trix

final class TrixRelativeLastActivityFormatterTests: XCTestCase {
    func testFormatsCompactRelativeBuckets() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-10), now: now), "1m")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-59 * 60), now: now), "59m")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-60 * 60), now: now), "1h")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-23 * 60 * 60), now: now), "23h")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-24 * 60 * 60), now: now), "1d")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-6 * 24 * 60 * 60), now: now), "6d")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-7 * 24 * 60 * 60), now: now), "1w")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-30 * 24 * 60 * 60), now: now), "1mo")
        XCTAssertEqual(TrixRelativeLastActivityFormatter.label(for: now.addingTimeInterval(-365 * 24 * 60 * 60), now: now), "1y")
    }

    func testHidesMissingActivityDate() {
        XCTAssertNil(TrixRelativeLastActivityFormatter.label(for: .distantPast))
    }
}
