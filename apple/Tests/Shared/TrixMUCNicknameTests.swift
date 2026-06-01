import XCTest
@testable import Trix

final class TrixMUCNicknameTests: XCTestCase {
    func testMUCNicknameDiffersForSameAccountAcrossResources() {
        let first = XMPPMartinService.mucNickname(
            from: "mihver@trix.selfhost.ru",
            resource: "trix-apple-11111111"
        )
        let second = XMPPMartinService.mucNickname(
            from: "mihver@trix.selfhost.ru",
            resource: "trix-apple-22222222"
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, "mihver-trix-apple-11111111")
        XCTAssertEqual(second, "mihver-trix-apple-22222222")
    }
}
