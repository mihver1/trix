import Foundation
import UIKit
import UserNotifications

@MainActor
final class IOSNotificationCoordinator {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return
        }

        _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func canPresentUserNotifications() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func postMessageNotification(identifier: String, title: String, body: String) async {
        guard await canPresentUserNotifications() else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

enum ApplePushRegistrationEnvironment {
    static var current: ApplePushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

func apnsTokenHexString(from deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
}
