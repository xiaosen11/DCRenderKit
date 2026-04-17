// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DCRenderKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "DCRenderKit",
            targets: ["DCRenderKit"]
        ),
    ],
    dependencies: [
        // Zero external dependencies by design.
        // DCRenderKit only depends on system frameworks (Metal, MetalKit, CoreImage optional, Vision optional).
    ],
    targets: [
        .target(
            name: "DCRenderKit",
            dependencies: [],
            path: "Sources/DCRenderKit",
            resources: [
                // Metal shaders will be added in Round 4+ as .process resources.
            ]
        ),
        .testTarget(
            name: "DCRenderKitTests",
            dependencies: ["DCRenderKit"],
            path: "Tests/DCRenderKitTests"
        ),
    ]
)
