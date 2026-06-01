import Foundation

struct TrixRoomNotificationCandidate: Equatable, Sendable {
    let room: TrixRoomSummary
    let profile: TrixRoomNotificationProfile
    let hasMention: Bool
}

enum TrixRoomNotificationPlanner {
    static func candidateRooms(
        previousRooms: [TrixRoomSummary],
        currentRooms: [TrixRoomSummary],
        payload: TrixRemoteNotificationPayload
    ) -> [TrixRoomSummary] {
        let previousUnreadByRoomID = Dictionary(
            previousRooms.map { (TrixRoomNotificationProfileSnapshot.normalizedRoomID($0.id), max($0.unreadCount, 0)) },
            uniquingKeysWith: { existing, _ in existing }
        )
        let payloadRoomKey = payload.roomID.map(TrixRoomNotificationProfileSnapshot.normalizedRoomID)
        let candidateKeys = Set(
            currentRooms.compactMap { room -> String? in
                let roomKey = TrixRoomNotificationProfileSnapshot.normalizedRoomID(room.id)
                let previousUnread = previousUnreadByRoomID[roomKey] ?? 0
                guard max(room.unreadCount, 0) > previousUnread || roomKey == payloadRoomKey else {
                    return nil
                }
                return roomKey
            }
        )

        return currentRooms.filter { room in
            candidateKeys.contains(TrixRoomNotificationProfileSnapshot.normalizedRoomID(room.id))
        }
    }

    static func localNotificationRequest(
        candidates: [TrixRoomNotificationCandidate],
        payload: TrixRemoteNotificationPayload,
        badgeCount: Int,
        excludingRoomID: String? = nil
    ) -> TrixLocalNotificationRequest? {
        let payloadRoomKey = payload.roomID.map(TrixRoomNotificationProfileSnapshot.normalizedRoomID)
        let excludedRoomKey = excludingRoomID.map(TrixRoomNotificationProfileSnapshot.normalizedRoomID)
        let notifyingCandidates = candidates.filter { candidate in
            let roomKey = TrixRoomNotificationProfileSnapshot.normalizedRoomID(candidate.room.id)
            guard roomKey != excludedRoomKey else {
                return false
            }

            switch candidate.profile {
            case .defaultProfile:
                return max(candidate.room.unreadCount, 0) > 0 ||
                    roomKey == payloadRoomKey
            case .muted:
                return false
            case .mentionsOnly:
                return candidate.hasMention
            }
        }

        let notificationUnreadCount = notifyingCandidates.reduce(0) { partialResult, candidate in
            let roomKey = TrixRoomNotificationProfileSnapshot.normalizedRoomID(candidate.room.id)
            let fallbackCount = roomKey == payloadRoomKey ? 1 : 0
            return partialResult + max(candidate.room.unreadCount, fallbackCount)
        }
        let finalUnreadCount = max(notificationUnreadCount, notifyingCandidates.isEmpty ? 0 : min(badgeCount, notificationUnreadCount))
        guard finalUnreadCount > 0 else {
            return nil
        }

        let body: String
        if finalUnreadCount == 1,
           notifyingCandidates.contains(where: { $0.profile == .mentionsOnly && $0.hasMention }) {
            body = "You were mentioned in an encrypted message"
        } else {
            body = finalUnreadCount == 1
                ? "New encrypted message"
                : "\(finalUnreadCount) unread encrypted messages"
        }

        let threadIdentifier = notifyingCandidates.count == 1
            ? notifyingCandidates[0].room.id
            : payload.roomID ?? "trix-unread"

        return TrixLocalNotificationRequest(
            title: "Trix",
            body: body,
            threadIdentifier: threadIdentifier,
            badgeCount: max(badgeCount, finalUnreadCount)
        )
    }

    static func timelineContainsMention(
        _ items: [TrixTimelineItem],
        accountID: String,
        newerThan previousActivityAt: Date?
    ) -> Bool {
        let tokens = mentionTokens(for: accountID)
        let accountKeys = accountMentionKeys(for: accountID)
        guard !tokens.isEmpty || !accountKeys.isEmpty else {
            return false
        }

        return items.contains { item in
            guard !item.isLocalEcho,
                  previousActivityAt.map({ item.timestamp > $0 }) ?? true else {
                return false
            }

            if !item.mentions.isEmpty {
                return item.mentions.contains { mention in
                    accountKeys.contains(normalizedUserKey(mention.targetUserID))
                }
            }

            let body = item.body.lowercased()
            return tokens.contains { token in
                body.contains(token)
            }
        }
    }

    private static func mentionTokens(for accountID: String) -> [String] {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return []
        }

        if normalized.hasPrefix("@"),
           let separator = normalized.firstIndex(of: ":") {
            let localpart = String(normalized[normalized.index(after: normalized.startIndex)..<separator])
            let server = String(normalized[normalized.index(after: separator)...])
            return [normalized, "\(localpart)@\(server)", "@\(localpart)"]
        }

        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localpart = parts.first,
              let server = parts.last,
              !localpart.isEmpty,
              !server.isEmpty else {
            return [normalized]
        }

        return [normalized, "@\(localpart):\(server)", "@\(localpart)"]
    }

    private static func accountMentionKeys(for accountID: String) -> Set<String> {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return []
        }

        var keys: Set<String> = [normalizedUserKey(normalized)]
        if normalized.hasPrefix("@"),
           let separator = normalized.firstIndex(of: ":") {
            let localpart = String(normalized[normalized.index(after: normalized.startIndex)..<separator])
            let server = String(normalized[normalized.index(after: separator)...])
            keys.insert("\(localpart)@\(server)")
        } else {
            let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
            if parts.count == 2,
               let localpart = parts.first,
               let server = parts.last,
               !localpart.isEmpty,
               !server.isEmpty {
                keys.insert("@\(localpart):\(server)")
            }
        }

        return keys
    }

    private static func normalizedUserKey(_ userID: String) -> String {
        (try? TrixUserIdentity.normalizedXMPPUserID(userID)) ??
            userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
