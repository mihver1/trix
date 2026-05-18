import Foundation
import Security
import XCTest
@testable import Trix

final class TrixMediaCacheTests: XCTestCase {
    func testMediaCacheStoreEncryptsDownloadedAttachmentAndLoadsItBack() throws {
        let accountID = "@media-\(UUID().uuidString):trix.selfhost.ru"
        let keychainService = "com.softgrid.trix.tests.media-cache.\(UUID().uuidString)"
        let directoryName = "MediaCacheTests-\(UUID().uuidString)"
        let store = TrixMediaCacheStore(
            keychainService: keychainService,
            keychainAccount: "key",
            directoryName: directoryName
        )
        defer {
            try? store.clearAll(accountID: accountID)
            deleteMediaCacheTestKeychainItem(service: keychainService)
            try? FileManager.default.removeItem(at: mediaCacheRootURL(directoryName: directoryName))
        }

        let item = Self.item(id: "$media-1", timestamp: 100)
        let download = TrixAttachmentDownload(
            filename: "private-photo.png",
            mimeType: "image/png",
            data: Data("secret media bytes".utf8)
        )

        let snapshot = try store.saveAttachment(
            download,
            for: item,
            accountID: accountID,
            policy: .unlimited,
            now: Date(timeIntervalSince1970: 110)
        )

        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertEqual(snapshot.totalBytes, Int64(download.data.count))

        let loaded = try store.loadAttachment(
            for: item,
            accountID: accountID,
            now: Date(timeIntervalSince1970: 120)
        )
        XCTAssertEqual(loaded?.filename, "private-photo.png")
        XCTAssertEqual(loaded?.mimeType, "image/png")
        XCTAssertEqual(loaded?.data, download.data)

        let rawCacheData = try allMediaCacheFileData(under: mediaCacheRootURL(directoryName: directoryName))
        XCTAssertNil(rawCacheData.range(of: download.data))
        XCTAssertFalse(String(data: rawCacheData, encoding: .utf8)?.contains("private-photo.png") == true)
    }

    func testMediaCacheRetentionPrunesByPerRoomCountAndAge() throws {
        let accountID = "@media-retention-\(UUID().uuidString):trix.selfhost.ru"
        let keychainService = "com.softgrid.trix.tests.media-retention.\(UUID().uuidString)"
        let directoryName = "MediaCacheRetentionTests-\(UUID().uuidString)"
        let store = TrixMediaCacheStore(
            keychainService: keychainService,
            keychainAccount: "key",
            directoryName: directoryName
        )
        defer {
            try? store.clearAll(accountID: accountID)
            deleteMediaCacheTestKeychainItem(service: keychainService)
            try? FileManager.default.removeItem(at: mediaCacheRootURL(directoryName: directoryName))
        }

        let oldItem = Self.item(id: "$old", timestamp: 100)
        let newItem = Self.item(id: "$new", timestamp: 200)
        let policy = TrixMediaCachePolicy(
            maxSizeBytes: nil,
            maxAgeDays: nil,
            maxMediaItemsPerRoom: 1
        )

        _ = try store.saveAttachment(Self.download("old"), for: oldItem, accountID: accountID, policy: policy)
        let retained = try store.saveAttachment(Self.download("new"), for: newItem, accountID: accountID, policy: policy)

        XCTAssertEqual(retained.entryCount, 1)
        XCTAssertNil(try store.loadAttachment(for: oldItem, accountID: accountID))
        XCTAssertEqual(try store.loadAttachment(for: newItem, accountID: accountID)?.data, Data("new".utf8))

        let agePolicy = TrixMediaCachePolicy(
            maxSizeBytes: nil,
            maxAgeDays: 7,
            maxMediaItemsPerRoom: nil
        )
        let pruned = try store.applyRetention(
            accountID: accountID,
            policy: agePolicy,
            now: Date(timeIntervalSince1970: 200 + 8 * 24 * 60 * 60)
        )

        XCTAssertEqual(pruned.entryCount, 0)
        XCTAssertNil(try store.loadAttachment(for: newItem, accountID: accountID))
    }

    func testMediaCacheCanClearSingleRoom() throws {
        let accountID = "@media-room-\(UUID().uuidString):trix.selfhost.ru"
        let keychainService = "com.softgrid.trix.tests.media-room.\(UUID().uuidString)"
        let directoryName = "MediaCacheRoomTests-\(UUID().uuidString)"
        let store = TrixMediaCacheStore(
            keychainService: keychainService,
            keychainAccount: "key",
            directoryName: directoryName
        )
        defer {
            try? store.clearAll(accountID: accountID)
            deleteMediaCacheTestKeychainItem(service: keychainService)
            try? FileManager.default.removeItem(at: mediaCacheRootURL(directoryName: directoryName))
        }

        let firstRoomItem = Self.item(id: "$one", roomID: "!one:trix.selfhost.ru", timestamp: 100)
        let secondRoomItem = Self.item(id: "$two", roomID: "!two:trix.selfhost.ru", timestamp: 101)

        _ = try store.saveAttachment(Self.download("one"), for: firstRoomItem, accountID: accountID, policy: .unlimited)
        _ = try store.saveAttachment(Self.download("two"), for: secondRoomItem, accountID: accountID, policy: .unlimited)

        let snapshot = try store.clearRoom(accountID: accountID, roomID: firstRoomItem.roomID)
        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertNil(try store.loadAttachment(for: firstRoomItem, accountID: accountID))
        XCTAssertEqual(try store.loadAttachment(for: secondRoomItem, accountID: accountID)?.data, Data("two".utf8))
    }

    private static func item(
        id: String,
        roomID: String = "!room:trix.selfhost.ru",
        timestamp: TimeInterval
    ) -> TrixTimelineItem {
        TrixTimelineItem(
            id: id,
            roomID: roomID,
            sender: "@peer:trix.selfhost.ru",
            timestamp: Date(timeIntervalSince1970: timestamp),
            body: "photo.png",
            isLocalEcho: false,
            attachment: TrixTimelineAttachment(
                kind: .image,
                filename: "photo-\(id).png",
                mimeType: "image/png",
                sizeBytes: 12,
                sourceJSON: "mock://media/\(id)",
                imageDimensions: TrixAttachmentImageDimensions(width: 1, height: 1)
            ),
            deliveryState: .delivered
        )
    }

    private static func download(_ value: String) -> TrixAttachmentDownload {
        TrixAttachmentDownload(
            filename: "\(value).png",
            mimeType: "image/png",
            data: Data(value.utf8)
        )
    }
}

private func deleteMediaCacheTestKeychainItem(service: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "key",
    ] as CFDictionary)
}

private func mediaCacheRootURL(directoryName: String) -> URL {
    FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("Trix", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
}

private func allMediaCacheFileData(under rootURL: URL) throws -> Data {
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
