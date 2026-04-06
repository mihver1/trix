import Foundation
import UIKit
import UserNotifications

struct MessageNotificationPayload: Equatable {
    let identifier: String
    let title: String
    let body: String
}

func messageNotificationPreviewServerSeq(
    item: LocalChatListItemSnapshot,
    previousItem: LocalChatListItemSnapshot?,
    currentAccountId: String,
    applicationIsActive: Bool,
    visibleChatID: String?
) -> UInt64? {
    guard item.chatType != .accountSync else {
        return nil
    }

    let currentPreviewServerSeq = item.previewServerSeq ?? 0
    let previousPreviewServerSeq = previousItem?.previewServerSeq ?? 0
    guard currentPreviewServerSeq > previousPreviewServerSeq else {
        return nil
    }
    guard item.previewSenderAccountId != currentAccountId else {
        return nil
    }
    guard !applicationIsActive || visibleChatID != item.chatId else {
        return nil
    }

    return currentPreviewServerSeq
}

func makeMessageNotificationPayloads(
    previousItems: [LocalChatListItemSnapshot],
    currentItems: [LocalChatListItemSnapshot],
    currentAccountId: String,
    applicationIsActive: Bool,
    visibleChatID: String?
) -> [MessageNotificationPayload] {
    let previousByChatId = Dictionary(
        uniqueKeysWithValues: previousItems.map { ($0.chatId, $0) }
    )

    return currentItems.compactMap { item in
        guard let previewServerSeq = messageNotificationPreviewServerSeq(
            item: item,
            previousItem: previousByChatId[item.chatId],
            currentAccountId: currentAccountId,
            applicationIsActive: applicationIsActive,
            visibleChatID: visibleChatID
        ) else {
            return nil
        }

        return MessageNotificationPayload(
            identifier: "chat-\(item.chatId)-\(previewServerSeq)",
            title: "\(item.displayTitle): New message",
            body: item.previewText ?? ""
        )
    }
}

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
