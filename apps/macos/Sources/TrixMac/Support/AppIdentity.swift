import Foundation

enum AppIdentity {
    static let teamIdentifier = "HGY33KYKQ2"
    static let bundleIdentifier = "com.softgrid.trixapp"

    static var applicationSupportDirectoryName: String {
        scopedApplicationSupportDirectoryName(arguments: ProcessInfo.processInfo.arguments)
    }

    static var keychainService: String {
        scopedKeychainService(arguments: ProcessInfo.processInfo.arguments)
    }

    static func scopedApplicationSupportDirectoryName(arguments: [String]) -> String {
        scopedIdentifier(arguments: arguments)
    }

    static func scopedKeychainService(arguments: [String]) -> String {
        scopedIdentifier(arguments: arguments)
    }

    private static func scopedIdentifier(arguments: [String]) -> String {
        guard arguments.contains(MacUITestLaunchArgument.enableUITesting) else {
            return bundleIdentifier
        }
        return bundleIdentifier + ".uitest"
    }
}
