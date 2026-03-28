import Foundation

struct ImportedAttachmentStore {
    private let fileManager: FileManager
    private let explicitRootURL: URL?
    private let appDirectoryName: String?

    init(
        fileManager: FileManager = .default,
        appDirectoryName: String = AppIdentity.applicationSupportDirectoryName
    ) {
        self.fileManager = fileManager
        self.explicitRootURL = nil
        self.appDirectoryName = appDirectoryName
    }

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.explicitRootURL = rootURL
        self.appDirectoryName = nil
    }

    func importFile(at sourceURL: URL) throws -> URL {
        let rootURL = try storageRootURL()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let destinationURL = rootURL.appendingPathComponent(
            UUID().uuidString.lowercased() + "-" + sourceURL.lastPathComponent,
            isDirectory: false
        )
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func removeImportedFileIfOwned(at url: URL) {
        guard let rootURL = try? storageRootURL() else {
            return
        }

        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return
        }
        guard fileManager.fileExists(atPath: filePath) else {
            return
        }

        try? fileManager.removeItem(at: url)
    }

    func removeAllImportedFiles() {
        guard let rootURL = try? storageRootURL() else {
            return
        }
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return
        }

        try? fileManager.removeItem(at: rootURL)
    }

    private func storageRootURL() throws -> URL {
        if let explicitRootURL {
            return explicitRootURL
        }

        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectoryName = appDirectoryName ?? AppIdentity.applicationSupportDirectoryName
        return cachesDirectory
            .appending(path: appDirectoryName)
            .appending(path: "imported-attachments")
    }
}
