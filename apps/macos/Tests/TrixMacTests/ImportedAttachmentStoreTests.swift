import XCTest
@testable import TrixMac

final class ImportedAttachmentStoreTests: XCTestCase {
    private var baseURL: URL!
    private var sourceRootURL: URL!
    private var importedRootURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trix-imported-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        sourceRootURL = baseURL.appendingPathComponent("source", isDirectory: true)
        importedRootURL = baseURL.appendingPathComponent("imported", isDirectory: true)

        try FileManager.default.createDirectory(at: sourceRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let baseURL {
            try? FileManager.default.removeItem(at: baseURL)
        }
    }

    func testImportFileCopiesSelectedAttachmentIntoOwnedStorage() throws {
        let sourceURL = sourceRootURL.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: sourceURL)

        let store = ImportedAttachmentStore(rootURL: importedRootURL)
        let importedURL = try store.importFile(at: sourceURL)

        XCTAssertNotEqual(importedURL, sourceURL)
        XCTAssertTrue(importedURL.path.hasPrefix(importedRootURL.path))
        XCTAssertEqual(importedURL.pathExtension, "txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))
        XCTAssertEqual(try Data(contentsOf: importedURL), Data("hello".utf8))
    }

    @MainActor
    func testAppModelImportComposerAttachmentUsesOwnedCopy() throws {
        let sourceURL = sourceRootURL.appendingPathComponent("draft.txt")
        try Data("draft".utf8).write(to: sourceURL)

        let model = AppModel(importedAttachmentStore: ImportedAttachmentStore(rootURL: importedRootURL))
        model.importComposerAttachment(from: sourceURL)

        let draft = try XCTUnwrap(model.composerAttachmentDraft)
        XCTAssertNotEqual(draft.fileURL, sourceURL)
        XCTAssertTrue(draft.fileURL.path.hasPrefix(importedRootURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: draft.fileURL), Data("draft".utf8))
        XCTAssertNil(model.lastErrorMessage)
    }
}
