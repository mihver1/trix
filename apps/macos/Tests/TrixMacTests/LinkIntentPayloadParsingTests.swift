import XCTest
@testable import TrixMac

@MainActor
final class LinkIntentPayloadParsingTests: XCTestCase {
    func testCompleteLinkAcceptsSnakeCasePayloadBeforeSurfacingBaseURLError() async throws {
        let suiteName = "trix-link-payload-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defer {
            defaults?.removePersistentDomain(forName: suiteName)
        }

        let model = AppModel(
            sessionStore: SessionStore(
                directoryName: "trix-link-payload-tests-\(UUID().uuidString)",
                fileName: "session.json"
            ),
            notificationPreferencesStore: NotificationPreferencesStore(defaults: defaults ?? .standard),
            notificationCoordinator: LocalNotificationCoordinator(center: nil)
        )

        model.linkDraft.linkPayload = """
        {
          "version": 1,
          "base_url": "/relative/path",
          "account_id": "11111111-1111-1111-1111-111111111111",
          "link_intent_id": "22222222-2222-2222-2222-222222222222",
          "link_token": "33333333-3333-3333-3333-333333333333"
        }
        """
        model.linkDraft.deviceDisplayName = "Regression Test Mac"

        await model.completeLink()

        let errorMessage = try XCTUnwrap(model.lastErrorMessage)
        XCTAssertNotEqual(errorMessage, "The data couldn’t be read because it is missing.")
        XCTAssertTrue(errorMessage.localizedCaseInsensitiveContains("base url"))
    }
}
