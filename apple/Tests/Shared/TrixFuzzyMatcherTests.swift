import Foundation
import XCTest
@testable import Trix

final class TrixFuzzyMatcherTests: XCTestCase {
    func testScoreTiersOrderExactPrefixWordPrefixSubsequence() throws {
        let exact = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ma", candidate: "Ma"))
        let prefix = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ma", candidate: "Marketing"))
        let wordPrefix = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ma", candidate: "Team Marketing"))
        let subsequence = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ma", candidate: "Almanac"))

        XCTAssertEqual(exact, 1000)
        XCTAssertTrue(exact > prefix, "Exact match must outrank a prefix match")
        XCTAssertTrue(prefix > wordPrefix, "Candidate prefix must outrank a later-word prefix")
        XCTAssertTrue(wordPrefix > subsequence, "Word prefix must outrank a plain subsequence")
    }

    func testScoreIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(TrixFuzzyMatcher.score(query: "alice", candidate: "ÁLÍCE"), 1000)
        XCTAssertEqual(
            TrixFuzzyMatcher.score(query: "AL", candidate: "alice"),
            TrixFuzzyMatcher.score(query: "al", candidate: "Alice")
        )
    }

    func testScoreRequiresFullSubsequence() {
        XCTAssertNotNil(
            TrixFuzzyMatcher.score(query: "ace", candidate: "Alice"),
            "Non-contiguous subsequences must still match"
        )
        XCTAssertNil(TrixFuzzyMatcher.score(query: "xyz", candidate: "Alice"))
        XCTAssertNil(TrixFuzzyMatcher.score(query: "alicee", candidate: "Alice"))
    }

    func testScoreRejectsEmptyQueryAndCandidate() {
        XCTAssertNil(TrixFuzzyMatcher.score(query: "", candidate: "Alice"))
        XCTAssertNil(TrixFuzzyMatcher.score(query: "   ", candidate: "Alice"))
        XCTAssertNil(TrixFuzzyMatcher.score(query: "alice", candidate: ""))
    }

    func testMultiTokenQueryMatchesDistinctWordPrefixes() throws {
        let multiToken = try XCTUnwrap(TrixFuzzyMatcher.score(query: "al ma", candidate: "Alice Marketing"))
        XCTAssertTrue(
            (601...700).contains(multiToken),
            "Token-per-word matches use the dedicated tier below word prefixes"
        )

        XCTAssertNil(
            TrixFuzzyMatcher.score(query: "al al", candidate: "Alice Marketing"),
            "Each token must claim a distinct word"
        )
    }

    func testSubsequenceWordBoundaryHitsBeatMidWordRuns() throws {
        let boundaryHits = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ds", candidate: "design sync"))
        let midWordRun = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ds", candidate: "feeds"))

        XCTAssertTrue(
            boundaryHits > midWordRun,
            "Word-boundary subsequence hits must outrank a late mid-word run"
        )
    }

    func testEarlierWordPrefixScoresHigher() throws {
        let secondWord = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ma", candidate: "Team Marketing"))
        let thirdWord = try XCTUnwrap(TrixFuzzyMatcher.score(query: "ma", candidate: "One Two Marketing"))

        XCTAssertTrue(secondWord > thirdWord)
    }

    func testRankedFiltersSortsAndKeepsInputOrderForTies() {
        let names = ["Almanac", "Team Marketing", "Marketing", "ma"]
        let ranked = TrixFuzzyMatcher.ranked(names, query: "ma") { [$0] }
        XCTAssertEqual(ranked, ["ma", "Marketing", "Team Marketing", "Almanac"])

        let tied = TrixFuzzyMatcher.ranked(["Design A", "Design B", "Ops"], query: "design") { name in
            [String(name.prefix(6))]
        }
        XCTAssertEqual(
            tied,
            ["Design A", "Design B"],
            "Ties keep input order and non-matching items are dropped"
        )
    }

    func testRankedReturnsInputUnchangedForEmptyQuery() {
        let names = ["Bravo", "Alpha"]
        XCTAssertEqual(TrixFuzzyMatcher.ranked(names, query: "  ") { [$0] }, names)
    }

    func testBestScoreUsesStrongestAlias() {
        let nameOnly = TrixFuzzyMatcher.bestScore(query: "bob", candidates: ["xyz", "Bobby"])
        XCTAssertEqual(nameOnly, TrixFuzzyMatcher.score(query: "bob", candidate: "Bobby"))

        let handleBeatsName = TrixFuzzyMatcher.bestScore(
            query: "bob",
            candidates: ["Robert", "bob@trix.selfhost.ru"]
        )
        XCTAssertEqual(
            handleBeatsName,
            TrixFuzzyMatcher.score(query: "bob", candidate: "bob@trix.selfhost.ru")
        )

        XCTAssertNil(TrixFuzzyMatcher.bestScore(query: "zz", candidates: ["Alice", "Bob"]))
    }
}

@MainActor
final class TrixApplicationBadgeCountTests: XCTestCase {
    func testBadgeSumsServerUnreadAndMarkedUnreadOnlyRooms() {
        let rooms = [
            Self.room(id: "a@trix.selfhost.ru", unreadCount: 3),
            Self.room(id: "b@trix.selfhost.ru", unreadCount: 0),
            Self.room(id: "c@trix.selfhost.ru", unreadCount: 0),
        ]

        XCTAssertEqual(
            TrixAppModel.applicationBadgeCount(
                rooms: rooms,
                markedUnreadRoomIDs: ["b@trix.selfhost.ru"]
            ),
            4,
            "3 server unread plus 1 for the marked-unread-only room"
        )
    }

    func testBadgeDoesNotDoubleCountMarkedRoomsWithServerUnread() {
        let rooms = [Self.room(id: "a@trix.selfhost.ru", unreadCount: 2)]

        XCTAssertEqual(
            TrixAppModel.applicationBadgeCount(
                rooms: rooms,
                markedUnreadRoomIDs: ["a@trix.selfhost.ru"]
            ),
            2
        )
    }

    func testBadgeNormalizesRoomIDsAndClampsNegativeCounts() {
        let rooms = [
            Self.room(id: "Alice@Trix.selfhost.ru", unreadCount: 0),
            Self.room(id: "broken@trix.selfhost.ru", unreadCount: -5),
        ]

        XCTAssertEqual(
            TrixAppModel.applicationBadgeCount(
                rooms: rooms,
                markedUnreadRoomIDs: ["alice@trix.selfhost.ru"]
            ),
            1
        )
    }

    private static func room(id: String, unreadCount: Int) -> TrixRoomSummary {
        TrixRoomSummary(
            id: id,
            name: id,
            kind: .direct,
            isEncrypted: true,
            unreadCount: unreadCount,
            lastMessagePreview: "Encrypted preview",
            lastActivityAt: Date(timeIntervalSince1970: 10)
        )
    }
}
