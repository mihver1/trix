// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = packageRoot
    .appendingPathComponent("../..")
    .standardizedFileURL
let environment = ProcessInfo.processInfo.environment
let fileManager = FileManager.default

let rustArtifactsPath: String
if let overridePath = environment["TRIX_CORE_ARTIFACTS_PATH"], !overridePath.isEmpty {
    rustArtifactsPath = URL(fileURLWithPath: overridePath).standardizedFileURL.path
} else {
    let preferredConfigurations = [
        environment["TRIX_CORE_BUILD_CONFIGURATION"],
        environment["CONFIGURATION"],
        "Release",
        "Debug",
    ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    let selectedArtifactsPath = preferredConfigurations
        .map { configuration in
            repoRoot
                .appendingPathComponent("target/macos-universal/\(configuration)")
                .standardizedFileURL
        }
        .first { artifactsURL in
            fileManager.fileExists(atPath: artifactsURL.appendingPathComponent("libtrix_core.a").path)
        }

    guard let selectedArtifactsPath else {
        fatalError(
            """
            Missing universal Rust archive for macOS SwiftPM builds.
            Run `apps/macos/scripts/build-trix-core-universal.sh` once (for Debug and/or Release), \
            or set TRIX_CORE_ARTIFACTS_PATH to a directory containing libtrix_core.a.
            """
        )
    }

    rustArtifactsPath = selectedArtifactsPath.path
}

let rustStaticLibraryPath = URL(fileURLWithPath: rustArtifactsPath)
    .appendingPathComponent("libtrix_core.a")
    .standardizedFileURL
    .path

let package = Package(
    name: "TrixMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "TrixMac",
            targets: ["TrixMac"]
        ),
    ],
    targets: [
        .systemLibrary(
            name: "trix_coreFFI",
            path: "Sources/trix_coreFFI"
        ),
        .executableTarget(
            name: "TrixMac",
            dependencies: ["trix_coreFFI"],
            path: "Sources/TrixMac",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    rustStaticLibraryPath,
                ]),
            ]
        ),
        .testTarget(
            name: "TrixMacTests",
            dependencies: ["TrixMac"],
            path: "Tests/TrixMacTests"
        ),
    ]
)
