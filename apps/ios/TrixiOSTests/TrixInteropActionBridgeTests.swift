import XCTest
@testable import Trix

final class TrixInteropActionBridgeTests: XCTestCase {
    func testActionDecoderParsesSendTextRequest() throws {
        let action = try TrixInteropAction.decode(
            """
            {"name":"sendText","actor":"ios-a","chatAlias":"dm-a-b","text":"hello"}
            """
        )
        XCTAssertEqual(action.name, .sendText)
        XCTAssertEqual(action.actor, "ios-a")
        XCTAssertEqual(action.chatAlias, "dm-a-b")
        XCTAssertEqual(action.text, "hello")
    }
}
