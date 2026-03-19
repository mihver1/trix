// swift-tools-version: 6.2

import PackageDescription

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
        .executableTarget(
            name: "TrixMac",
            path: "Sources/TrixMac"
        ),
        .testTarget(
            name: "TrixMacTests",
            dependencies: ["TrixMac"],
            path: "Tests/TrixMacTests"
        ),
    ]
)
