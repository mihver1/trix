import Foundation
import XCTest
@testable import Trix

final class TrixDraftStoreTests: XCTestCase {
    func testDraftRoundtripPersistsTextAndContextTargets() throws {
        let accountJID = "@drafts-\(UUID().uuidString):trix.selfhost.ru"
        let directoryName = "ComposerDraftsTests-\(UUID().uuidString)"
        let store = Self.makeStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixDraftTestRootURL(directoryName: directoryName))
        }

        let draft = TrixComposerDraft(
            text: "hello from a draft",
            replyTargetMessageID: "$reply-target",
            threadTargetMessageID: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        try store.setDraft(draft, accountJID: accountJID, roomID: "!Room-A:trix.selfhost.ru")

        let reloaded = try store.draft(accountJID: accountJID, roomID: "!room-a:trix.selfhost.ru")
        XCTAssertEqual(reloaded?.text, "hello from a draft")
        XCTAssertEqual(reloaded?.replyTargetMessageID, "$reply-target")
        XCTAssertNil(reloaded?.threadTargetMessageID)

        // A second store instance with the same key must read the same data.
        let secondStore = Self.makeStore(directoryName: directoryName)
        let drafts = try secondStore.load(accountJID: accountJID)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts["!room-a:trix.selfhost.ru"]?.text, "hello from a draft")
    }

    func testClearDraftRemovesOnlyRequestedRoom() throws {
        let accountJID = "@drafts-clear-\(UUID().uuidString):trix.selfhost.ru"
        let directoryName = "ComposerDraftsClearTests-\(UUID().uuidString)"
        let store = Self.makeStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixDraftTestRootURL(directoryName: directoryName))
        }

        try store.setDraft(
            TrixComposerDraft(text: "first"),
            accountJID: accountJID,
            roomID: "!one:trix.selfhost.ru"
        )
        try store.setDraft(
            TrixComposerDraft(text: "second"),
            accountJID: accountJID,
            roomID: "!two:trix.selfhost.ru"
        )

        try store.clearDraft(accountJID: accountJID, roomID: "!one:trix.selfhost.ru")

        XCTAssertNil(try store.draft(accountJID: accountJID, roomID: "!one:trix.selfhost.ru"))
        XCTAssertEqual(try store.draft(accountJID: accountJID, roomID: "!two:trix.selfhost.ru")?.text, "second")
    }

    func testDraftFileDoesNotContainPlaintext() throws {
        let accountJID = "@drafts-crypto-\(UUID().uuidString):trix.selfhost.ru"
        let directoryName = "ComposerDraftsCryptoTests-\(UUID().uuidString)"
        let store = Self.makeStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixDraftTestRootURL(directoryName: directoryName))
        }

        let secret = "very-secret-draft-body-\(UUID().uuidString)"
        try store.setDraft(
            TrixComposerDraft(text: secret),
            accountJID: accountJID,
            roomID: "!secret:trix.selfhost.ru"
        )

        let rawData = try trixAllDraftTestFileData(
            under: trixDraftTestRootURL(directoryName: directoryName)
        )
        XCTAssertFalse(rawData.isEmpty)
        XCTAssertNil(rawData.range(of: Data(secret.utf8)))
        XCTAssertNil(rawData.range(of: Data("!secret:trix.selfhost.ru".utf8)))
    }

    func testEmptyDraftIsDroppedOnSave() throws {
        let accountJID = "@drafts-empty-\(UUID().uuidString):trix.selfhost.ru"
        let directoryName = "ComposerDraftsEmptyTests-\(UUID().uuidString)"
        let store = Self.makeStore(directoryName: directoryName)
        defer {
            try? store.clear(accountJID: accountJID)
            try? FileManager.default.removeItem(at: trixDraftTestRootURL(directoryName: directoryName))
        }

        try store.save(
            ["!one:trix.selfhost.ru": TrixComposerDraft(text: "   ")],
            accountJID: accountJID
        )

        XCTAssertTrue(try store.load(accountJID: accountJID).isEmpty)
    }

    private static func makeStore(directoryName: String) -> TrixDraftStore {
        TrixDraftStore(
            directoryName: directoryName,
            keySource: .memory(Data(repeating: 0xA7, count: 32))
        )
    }
}

private func trixDraftTestRootURL(directoryName: String) -> URL {
    FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("Trix", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
}

private func trixAllDraftTestFileData(under rootURL: URL) throws -> Data {
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        return Data()
    }

    var result = Data()
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            continue
        }

        result.append(try Data(contentsOf: fileURL))
    }
    return result
}
