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
                // All Metal shaders live under Shaders/; SPM compiles them
                // into the default metallib bundled with the target. Swift
                // filter structs live under Filters/ and must stay out of
                // this rule (otherwise SPM reclassifies .swift files as
                // resources and silently skips compiling them).
                .process("Shaders"),
            ]
        ),
        .testTarget(
            name: "DCRenderKitTests",
            dependencies: ["DCRenderKit"],
            path: "Tests/DCRenderKitTests"
        ),
    ]
)
