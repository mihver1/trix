import Foundation
import Security
import XCTest
@testable import Trix

final class TrixStickerTests: XCTestCase {
    func testTelegramStickerPackReferenceParsesPublicLinks() throws {
        XCTAssertEqual(
            try TrixTelegramStickerPackReference.normalizedName(from: "https://t.me/addstickers/Trix_Friends"),
            "Trix_Friends"
        )
        XCTAssertEqual(
            try TrixTelegramStickerPackReference.normalizedName(from: "t.me/addstickers/Trix_Friends"),
            "Trix_Friends"
        )
        XCTAssertEqual(
            try TrixTelegramStickerPackReference.normalizedName(from: "Trix_Friends"),
            "Trix_Friends"
        )
        XCTAssertThrowsError(try TrixTelegramStickerPackReference.normalizedName(from: "https://example.com/addstickers/Trix"))
        XCTAssertThrowsError(try TrixTelegramStickerPackReference.normalizedName(from: "example.com/addstickers/Trix"))
    }

    func testStickerLibraryStoreSavesEncryptedPackAndDeduplicatesByPackID() throws {
        let accountID = "@stickers-\(UUID().uuidString):trix.selfhost.ru"
        let keychainService = "com.softgrid.trix.tests.stickers.\(UUID().uuidString)"
        let store = TrixStickerLibraryStore(
            keychainService: keychainService,
            keychainAccount: "key",
            directoryName: "StickerLibraryTests-\(UUID().uuidString)"
        )
        defer {
            try? store.clear(accountID: accountID)
            deleteTestKeychainItem(service: keychainService)
        }

        let source = TrixStickerSource(kind: .telegram, name: "FakePack", url: "https://t.me/addstickers/FakePack")
        let sticker = TrixSticker(
            id: "telegram:fake-static-unique",
            packID: "telegram:fakepack",
            emoji: "🙂",
            filename: "fake.png",
            mimeType: "image/png",
            sizeBytes: 4,
            imageDimensions: TrixAttachmentImageDimensions(width: 1, height: 1),
            source: source
        )
        let pack = TrixStickerPack(
            id: "telegram:fakepack",
            title: "Fake Pack",
            source: source,
            stickers: [sticker],
            importedAt: Date()
        )

        _ = try store.save(pack: pack, dataByStickerID: [sticker.id: Data([1, 2, 3, 4])], accountID: accountID)
        let reloaded = try store.load(accountID: accountID)
        XCTAssertEqual(reloaded.packs.count, 1)
        XCTAssertEqual(reloaded.packs.first?.stickers, [sticker])
        XCTAssertEqual(reloaded.dataByStickerID[sticker.id], Data([1, 2, 3, 4]))

        _ = try store.save(pack: pack, dataByStickerID: [sticker.id: Data([5, 6])], accountID: accountID)
        let deduped = try store.load(accountID: accountID)
        XCTAssertEqual(deduped.packs.count, 1)
        XCTAssertEqual(deduped.dataByStickerID[sticker.id], Data([5, 6]))
    }

    func testStickerLibraryStoreDeletesSinglePackAndItsData() throws {
        let accountID = "@stickers-delete-\(UUID().uuidString):trix.selfhost.ru"
        let keychainService = "com.softgrid.trix.tests.stickers-delete.\(UUID().uuidString)"
        let store = TrixStickerLibraryStore(
            keychainService: keychainService,
            keychainAccount: "key",
            directoryName: "StickerLibraryDeleteTests-\(UUID().uuidString)"
        )
        defer {
            try? store.clear(accountID: accountID)
            deleteTestKeychainItem(service: keychainService)
        }

        let source = TrixStickerSource(kind: .telegram, name: "FakePack", url: "https://t.me/addstickers/FakePack")
        let firstSticker = sticker(id: "telegram:first", packID: "telegram:first-pack", source: source)
        let secondSticker = sticker(id: "telegram:second", packID: "telegram:second-pack", source: source)
        let firstPack = pack(id: "telegram:first-pack", title: "First Pack", source: source, stickers: [firstSticker])
        let secondPack = pack(id: "telegram:second-pack", title: "Second Pack", source: source, stickers: [secondSticker])

        _ = try store.save(pack: firstPack, dataByStickerID: [firstSticker.id: Data([1])], accountID: accountID)
        _ = try store.save(pack: secondPack, dataByStickerID: [secondSticker.id: Data([2])], accountID: accountID)

        let state = try store.deletePack(id: firstPack.id, accountID: accountID)
        XCTAssertEqual(state.packs.map(\.id), [secondPack.id])
        XCTAssertNil(state.dataByStickerID[firstSticker.id])
        XCTAssertEqual(state.dataByStickerID[secondSticker.id], Data([2]))

        let stats = try store.stats(accountID: accountID)
        XCTAssertEqual(stats.packCount, 1)
        XCTAssertEqual(stats.stickerCount, 1)
        XCTAssertEqual(stats.totalBytes, 1)
    }

    @MainActor
    func testReceivedTelegramStickerMetadataImportsWholePack() async throws {
        let accountID = "@me:trix.selfhost.ru"
        let keychainService = "com.softgrid.trix.tests.received-stickers.\(UUID().uuidString)"
        let store = TrixStickerLibraryStore(
            keychainService: keychainService,
            keychainAccount: "key",
            directoryName: "ReceivedStickerLibraryTests-\(UUID().uuidString)"
        )
        defer {
            try? store.clear(accountID: accountID)
            deleteTestKeychainItem(service: keychainService)
        }

        let session = TrixSession(
            userID: accountID,
            deviceID: "TEST",
            homeserverURL: XMPPClientConfiguration.connectionURL,
            accessToken: "test-password",
            refreshToken: nil,
            oidcData: nil,
            sdkStoreID: "test",
            createdAt: Date()
        )
        let model = TrixAppModel(
            sessionStore: StaticSessionStore(session: session),
            registrationService: MockInviteRegistrationService(),
            stickerImportService: TestStickerImportService(),
            stickerLibraryStore: store,
            trixService: MockTrixService()
        )
        await model.start()

        let metadata = TrixStickerAttachmentMetadata(
            stickerID: "telegram:incoming",
            packID: "telegram:fakepack",
            packTitle: "Incoming Pack",
            source: TrixStickerSource(kind: .telegram, name: "FakePack", url: "https://t.me/addstickers/FakePack"),
            emoji: "🙂"
        )
        await model.importStickerPack(from: metadata)

        XCTAssertEqual(model.stickerPacks.count, 1)
        XCTAssertEqual(model.stickerPacks.first?.stickers.count, 2)
        XCTAssertEqual(model.stickerPacks.first?.id, "telegram:fakepack")
    }
}

private func sticker(id: String, packID: String, source: TrixStickerSource) -> TrixSticker {
    TrixSticker(
        id: id,
        packID: packID,
        emoji: "🙂",
        filename: "\(id).png",
        mimeType: "image/png",
        sizeBytes: 1,
        imageDimensions: TrixAttachmentImageDimensions(width: 1, height: 1),
        source: source
    )
}

private func pack(
    id: String,
    title: String,
    source: TrixStickerSource,
    stickers: [TrixSticker]
) -> TrixStickerPack {
    TrixStickerPack(
        id: id,
        title: title,
        source: source,
        stickers: stickers,
        importedAt: Date()
    )
}

private func deleteTestKeychainItem(service: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "key",
    ] as CFDictionary)
}

private struct StaticSessionStore: TrixSessionStore {
    let session: TrixSession

    func loadSession() throws -> TrixSession? {
        session
    }

    func saveSession(_ session: TrixSession) throws {
    }

    func clearSession() throws {
    }
}

private struct TestStickerImportService: TrixStickerImportService {
    func resolveTelegramStickerPack(_ reference: String, session: TrixSession) async throws -> TrixTelegramStickerPackImport {
        let source = TrixStickerSource(kind: .telegram, name: "FakePack", url: "https://t.me/addstickers/FakePack")
        return TrixTelegramStickerPackImport(
            packID: "telegram:fakepack",
            title: "Fake Pack",
            source: source,
            stickers: [
                item(id: "telegram:one", fileToken: "one", source: source),
                item(id: "telegram:two", fileToken: "two", source: source),
            ],
            unsupportedStickerCount: 1
        )
    }

    func downloadTelegramStickerFile(_ sticker: TrixTelegramStickerImportItem, session: TrixSession) async throws -> TrixTelegramStickerFileDownload {
        TrixTelegramStickerFileDownload(
            filename: "\(sticker.id).png",
            mimeType: "image/png",
            data: Data(sticker.id.utf8)
        )
    }

    private func item(id: String, fileToken: String, source: TrixStickerSource) -> TrixTelegramStickerImportItem {
        TrixTelegramStickerImportItem(
            id: id,
            packID: "telegram:fakepack",
            emoji: "🙂",
            filename: "\(id).png",
            mimeType: "image/png",
            sizeBytes: nil,
            imageDimensions: TrixAttachmentImageDimensions(width: 1, height: 1),
            source: source,
            fileToken: fileToken
        )
    }
}
