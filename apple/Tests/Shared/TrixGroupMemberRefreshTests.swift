import XCTest
@testable import Trix

final class TrixGroupMemberRefreshTests: XCTestCase {
    func testMembersReturnsCachedGroupMembersWithoutOpeningLiveConnection() async throws {
        let cacheIdentifier = "member-cache-\(UUID().uuidString)"
        let profile = try XCTUnwrap(TrixLocalProfileConfiguration(rawName: cacheIdentifier))
        let accountJID = "mihver1@trix.selfhost.ru"
        let roomID = "quartet-91505e7a@conference.trix.selfhost.ru"
        let cacheStore = TrixGroupRoomCacheStore(
            directoryName: "GroupMemberCache-Test-\(profile.name)",
            keySource: .memory(Data(repeating: 7, count: 32)),
            migratesLegacyKeychainItems: false
        )
        try cacheStore.save(
            TrixCachedGroupRoom(
                roomID: roomID,
                name: "Quartet",
                memberUserIDs: [
                    accountJID,
                    "akim@trix.selfhost.ru",
                    "slayer@trix.selfhost.ru",
                ],
                lastActivityAt: Date(timeIntervalSince1970: 100)
            ),
            accountJID: accountJID
        )
        defer {
            try? cacheStore.clear(accountJID: accountJID, roomID: roomID)
        }

        let service = XMPPMartinService(testCacheIdentifier: cacheIdentifier)
        let members = try await service.members(
            roomID: roomID,
            session: TrixSession(
                userID: accountJID,
                deviceID: "trix-apple-test",
                homeserverURL: URL(string: "https://trix.selfhost.ru")!,
                accessToken: "",
                refreshToken: nil,
                oidcData: nil,
                sdkStoreID: "xmpp-martin",
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertEqual(Set(members.map { $0.userID.lowercased() }), [
            accountJID,
            "akim@trix.selfhost.ru",
            "slayer@trix.selfhost.ru",
        ])
    }

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
