import XCTest
import ObjectiveC.runtime
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

    @MainActor
    func testAppModelImportComposerAttachmentStartsSecurityScopedAccessBeforeCopying() throws {
        let sourceURL = sourceRootURL.appendingPathComponent("sandboxed.txt")
        try Data("sandboxed".utf8).write(to: sourceURL)

        let swizzler = SecurityScopedURLMethodSwizzler()
        defer { _ = swizzler }

        let fileManager = SecurityScopedAccessEnforcingFileManager()
        let model = AppModel(
            importedAttachmentStore: ImportedAttachmentStore(
                rootURL: importedRootURL,
                fileManager: fileManager
            )
        )

        model.importComposerAttachment(from: sourceURL)

        let draft = try XCTUnwrap(model.composerAttachmentDraft)
        XCTAssertEqual(try Data(contentsOf: draft.fileURL), Data("sandboxed".utf8))
        XCTAssertEqual(SecurityScopedURLAccessSpy.shared.startCount, 1)
        XCTAssertEqual(SecurityScopedURLAccessSpy.shared.stopCount, 1)
        XCTAssertTrue(SecurityScopedURLAccessSpy.shared.activePaths.isEmpty)
        XCTAssertNil(model.lastErrorMessage)
    }
}

private final class SecurityScopedURLAccessSpy: @unchecked Sendable {
    static let shared = SecurityScopedURLAccessSpy()

    private let lock = NSLock()
    private var _activePaths = Set<String>()
    private var _startCount = 0
    private var _stopCount = 0

    var activePaths: Set<String> {
        lock.withLock { _activePaths }
    }

    var startCount: Int {
        lock.withLock { _startCount }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    func reset() {
        lock.withLock {
            _activePaths.removeAll()
            _startCount = 0
            _stopCount = 0
        }
    }

    func beginAccess(for path: String) {
        lock.withLock {
            _activePaths.insert(path)
            _startCount += 1
        }
    }

    func endAccess(for path: String) {
        lock.withLock {
            _activePaths.remove(path)
            _stopCount += 1
        }
    }
}

private final class SecurityScopedAccessEnforcingFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard SecurityScopedURLAccessSpy.shared.activePaths.contains(srcURL.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: srcURL.path])
        }

        try super.copyItem(at: srcURL, to: dstURL)
    }
}

private final class SecurityScopedURLMethodSwizzler {
    private static let startSelector = #selector(NSURL.startAccessingSecurityScopedResource)
    private static let stopSelector = #selector(NSURL.stopAccessingSecurityScopedResource)
    private static let testStartSelector = #selector(NSURL.trix_test_startAccessingSecurityScopedResource)
    private static let testStopSelector = #selector(NSURL.trix_test_stopAccessingSecurityScopedResource)

    init() {
        SecurityScopedURLAccessSpy.shared.reset()
        Self.exchange(Self.startSelector, Self.testStartSelector)
        Self.exchange(Self.stopSelector, Self.testStopSelector)
    }

    deinit {
        Self.exchange(Self.startSelector, Self.testStartSelector)
        Self.exchange(Self.stopSelector, Self.testStopSelector)
        SecurityScopedURLAccessSpy.shared.reset()
    }

    private static func exchange(_ original: Selector, _ swizzled: Selector) {
        guard
            let originalMethod = class_getInstanceMethod(NSURL.self, original),
            let swizzledMethod = class_getInstanceMethod(NSURL.self, swizzled)
        else {
            XCTFail("Failed to swizzle security-scoped NSURL methods")
            return
        }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }
}

private extension NSURL {
    @objc func trix_test_startAccessingSecurityScopedResource() -> Bool {
        SecurityScopedURLAccessSpy.shared.beginAccess(for: (self as URL).path)
        return true
    }

    @objc func trix_test_stopAccessingSecurityScopedResource() {
        SecurityScopedURLAccessSpy.shared.endAccess(for: (self as URL).path)
    }
}
