import XCTest
@testable import TrixMac

final class TrixMacInteropActionBridgeTests: XCTestCase {
    func testActionDecoderParsesSendTextRequest() throws {
        let action = try TrixMacInteropAction.decode(
            """
            {"name":"sendText","actor":"mac-a","chatAlias":"dm-a-b","text":"hello"}
            """
        )
        XCTAssertEqual(action.name, .sendText)
        XCTAssertEqual(action.actor, "mac-a")
        XCTAssertEqual(action.chatAlias, "dm-a-b")
        XCTAssertEqual(action.text, "hello")
    }
}
