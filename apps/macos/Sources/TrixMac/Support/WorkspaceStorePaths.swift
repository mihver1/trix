import Foundation

struct WorkspaceStorePaths: Sendable {
    let rootURL: URL
    let localHistoryURL: URL
    let syncStateURL: URL
    let attachmentsRootURL: URL
    let mlsStateRootURL: URL

    static func forAccount(
        _ accountId: UUID,
        appDirectoryName: String = AppIdentity.applicationSupportDirectoryName
    ) throws -> WorkspaceStorePaths {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let rootURL = appSupport
            .appending(path: appDirectoryName)
            .appending(path: "workspaces")
            .appending(path: accountId.uuidString.lowercased())

        return WorkspaceStorePaths(
            rootURL: rootURL,
            localHistoryURL: rootURL.appending(path: "local-history.sqlite"),
            syncStateURL: rootURL.appending(path: "sync-state.sqlite"),
            attachmentsRootURL: rootURL.appending(path: "attachments"),
            mlsStateRootURL: rootURL.appending(path: "mls-state")
        )
    }
}
