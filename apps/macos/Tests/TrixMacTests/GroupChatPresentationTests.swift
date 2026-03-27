import Foundation
import Testing
@testable import TrixMac

@Test
func groupSummaryUsesParticipantNamesWhenTitleIsMissing() {
    let currentAccountID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let summary = ChatSummary(
        chatId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        chatType: .group,
        title: nil,
        lastServerSeq: 0,
        epoch: 0,
        pendingMessageCount: 0,
        lastMessage: nil,
        participantProfiles: [
            profile("You", accountId: currentAccountID),
            profile("Alex", accountId: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!),
            profile("Sam", accountId: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!),
            profile("Taylor", accountId: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!),
            profile("Jordan", accountId: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!),
        ]
    )

    #expect(summary.displayTitle(for: currentAccountID) == "Alex, Sam, Taylor +1")
    #expect(summary.subtitle(for: currentAccountID) == "Alex, Sam, Taylor, Jordan")
}

@Test
func groupSummaryFallsBackToUntitledGroupWithoutOtherParticipants() {
    let currentAccountID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let summary = ChatSummary(
        chatId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        chatType: .group,
        title: nil,
        lastServerSeq: 0,
        epoch: 0,
        pendingMessageCount: 0,
        lastMessage: nil,
        participantProfiles: [
            profile("You", accountId: currentAccountID),
        ]
    )

    #expect(summary.displayTitle(for: currentAccountID) == "Untitled Group")
    #expect(summary.subtitle(for: currentAccountID) == "Group")
}

@Test
func groupDetailPresentationMatchesSummaryRules() {
    let currentAccountID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let detail = ChatDetailResponse(
        chatId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        chatType: .group,
        title: nil,
        lastServerSeq: 12,
        pendingMessageCount: 0,
        epoch: 4,
        lastCommitMessageId: nil,
        lastMessage: nil,
        participantProfiles: [
            profile("You", accountId: currentAccountID),
            profile("Alex", accountId: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!),
            profile("Sam", accountId: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!),
        ],
        members: [
            member(currentAccountID),
            member(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!),
            member(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!),
        ],
        deviceMembers: []
    )

    #expect(detail.displayTitle(for: currentAccountID) == "Alex, Sam")
    #expect(detail.subtitle(for: currentAccountID) == "Alex, Sam")
}

private func profile(_ name: String, accountId: UUID) -> ChatParticipantProfileSummary {
    ChatParticipantProfileSummary(
        accountId: accountId,
        handle: nil,
        profileName: name,
        profileBio: nil
    )
}

private func member(_ accountId: UUID) -> ChatMemberSummary {
    ChatMemberSummary(
        accountId: accountId,
        role: "member",
        membershipStatus: "active"
    )
}
