// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustArtifactsPath = packageRoot
    .appendingPathComponent("../../target/debug")
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
                    "\(rustArtifactsPath)/libtrix_core.a",
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
