import XCTest
@testable import Trix

final class TrixGroupMemberRefreshTests: XCTestCase {
    func testAuthoritativeAffiliationRefreshExcludesStaleCachedLeaver() {
        let refresh = XMPPMartinService.mergedGroupMemberRefresh(
            cachedMemberUserIDs: [
                "owner@trix.selfhost.ru",
                "peer@trix.selfhost.ru",
                "third@trix.selfhost.ru",
            ],
            occupantUserIDs: [
                "owner@trix.selfhost.ru",
                "third@trix.selfhost.ru",
            ],
            affiliationMembers: [
                XMPPGroupAffiliationMember(userID: "owner@trix.selfhost.ru"),
                XMPPGroupAffiliationMember(userID: "third@trix.selfhost.ru"),
            ],
            accountJID: "owner@trix.selfhost.ru",
            affiliationsComplete: true
        )

        let memberIDs = Set(refresh.members.map { $0.userID.lowercased() })
        XCTAssertEqual(memberIDs, [
            "owner@trix.selfhost.ru",
            "third@trix.selfhost.ru",
        ])
        XCTAssertFalse(memberIDs.contains("peer@trix.selfhost.ru"))
        XCTAssertTrue(refresh.shouldReplaceCachedMembers)
    }

    func testIncompleteAffiliationRefreshKeepsCachedMembersAsFallback() {
        let refresh = XMPPMartinService.mergedGroupMemberRefresh(
            cachedMemberUserIDs: [
                "owner@trix.selfhost.ru",
                "peer@trix.selfhost.ru",
                "third@trix.selfhost.ru",
            ],
            occupantUserIDs: [
                "owner@trix.selfhost.ru",
            ],
            affiliationMembers: [
                XMPPGroupAffiliationMember(userID: "owner@trix.selfhost.ru"),
            ],
            accountJID: "owner@trix.selfhost.ru",
            affiliationsComplete: false
        )

        let memberIDs = Set(refresh.members.map { $0.userID.lowercased() })
        XCTAssertTrue(memberIDs.contains("peer@trix.selfhost.ru"))
        XCTAssertFalse(refresh.shouldReplaceCachedMembers)
    }
}
