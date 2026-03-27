import XCTest
@testable import Trix

final class FormAndPayloadTests: XCTestCase {
    @MainActor
    func testCreateAccountFormRequiresTrimmedProfileNameAndDeviceName() {
        var form = CreateAccountForm()
        form.profileName = "   "
        form.deviceDisplayName = "Alice iPhone"
        XCTAssertFalse(form.canSubmit)

        form.profileName = " Alice "
        form.deviceDisplayName = "\n  "
        XCTAssertFalse(form.canSubmit)

        form.deviceDisplayName = " Alice iPhone "
        XCTAssertTrue(form.canSubmit)
    }

    @MainActor
    func testLinkExistingAccountFormRequiresTrimmedPayloadAndDeviceName() {
        var form = LinkExistingAccountForm()
        form.linkPayload = "   "
        form.deviceDisplayName = "Alice iPhone"
        XCTAssertFalse(form.canSubmit)

        form.linkPayload = "{\"version\":1}"
        form.deviceDisplayName = "  "
        XCTAssertFalse(form.canSubmit)

        form.deviceDisplayName = " Alice iPhone "
        XCTAssertTrue(form.canSubmit)
    }

    @MainActor
    func testEditProfileFormCopiesExistingProfileAndValidatesTrimmedName() {
        let profile = AccountProfileResponse(
            accountId: "account-1",
            handle: "alice",
            profileName: "Alice",
            profileBio: "Hello there",
            deviceId: "device-1",
            deviceStatus: .active
        )
        let seeded = EditProfileForm(profile: profile)
        XCTAssertEqual(seeded.profileName, "Alice")
        XCTAssertEqual(seeded.handle, "alice")
        XCTAssertEqual(seeded.profileBio, "Hello there")
        XCTAssertTrue(seeded.canSubmit)

        var empty = EditProfileForm()
        empty.profileName = "   "
        XCTAssertFalse(empty.canSubmit)
        empty.profileName = " Alice Updated "
        XCTAssertTrue(empty.canSubmit)
    }

    func testLinkIntentPayloadParseTrimsWhitespace() throws {
        let payload = try LinkIntentPayload.parse(
            """

              {
                "version": 1,
                "base_url": "http://127.0.0.1:8080",
                "account_id": "account-1",
                "link_intent_id": "intent-1",
                "link_token": "token-1"
              }

            """
        )

        XCTAssertEqual(payload.version, 1)
        XCTAssertEqual(payload.baseURL, "http://127.0.0.1:8080")
        XCTAssertEqual(payload.accountId, "account-1")
        XCTAssertEqual(payload.linkIntentId, "intent-1")
        XCTAssertEqual(payload.linkToken, "token-1")
    }

    func testLinkIntentPayloadParseRejectsMalformedJSON() {
        XCTAssertThrowsError(try LinkIntentPayload.parse("{not-json")) { error in
            XCTAssertTrue(error is DecodingError || error is CocoaError)
        }
    }

    func testStringHelpersTrimAndCollapseWhitespaceOnlyValuesToNil() {
        XCTAssertEqual("  hello  \n".trix_trimmed(), "hello")
        XCTAssertEqual("  hello  \n".trix_trimmedOrNil(), "hello")
        XCTAssertNil(" \n\t ".trix_trimmedOrNil())
    }
}
