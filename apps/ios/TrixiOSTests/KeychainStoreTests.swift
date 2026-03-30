import Foundation
import Security
import XCTest
@testable import Trix

final class KeychainStoreTests: XCTestCase {
    func testInteractionNotAllowedErrorDescriptionMentionsLockedDevice() {
        let error = KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed)

        XCTAssertEqual(
            error.errorDescription,
            "Secure data is unavailable until the device is unlocked."
        )
    }

    func testKeychainOSStatusReturnsUnexpectedStatusFromTypedError() {
        let error = KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed)

        XCTAssertEqual(keychainOSStatus(from: error), errSecInteractionNotAllowed)
    }

    func testKeychainOSStatusReadsWrappedOSStatusNSErrorRecursively() {
        let wrappedError = NSError(
            domain: "WrappedError",
            code: -1,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(errSecInteractionNotAllowed)
                ),
            ]
        )

        XCTAssertEqual(keychainOSStatus(from: wrappedError), errSecInteractionNotAllowed)
    }
}
