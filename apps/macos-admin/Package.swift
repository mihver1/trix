// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TrixMacAdmin",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "TrixMacAdmin",
            targets: ["TrixMacAdmin"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "TrixMacAdmin",
            path: "Sources/TrixMacAdmin"
        ),
        .testTarget(
            name: "TrixMacAdminTests",
            dependencies: ["TrixMacAdmin"],
            path: "Tests/TrixMacAdminTests"
        ),
    ]
)
