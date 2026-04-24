// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DCRenderKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "DCRenderKit",
            targets: ["DCRenderKit"]
        ),
    ],
    dependencies: [
        // Zero external dependencies by design.
        // DCRenderKit only depends on system frameworks (Metal, MetalKit,
        // CoreImage optional, Vision optional, MetalPerformanceShaders optional).
    ],
    targets: [
        .target(
            name: "DCRenderKit",
            dependencies: [],
            path: "Sources/DCRenderKit",
            resources: [
                // All Metal shaders live under Shaders/; SPM compiles them
                // into the default metallib bundled with the target. Swift
                // filter structs live under Filters/ and stay out of this
                // rule (otherwise SPM reclassifies .swift files as resources
                // and silently skips compiling them).
                .process("Shaders"),
            ],
            swiftSettings: [
                // Full Swift 6 strict concurrency. Every captured value must
                // be Sendable (or @unchecked with justification).
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "DCRenderKitTests",
            dependencies: ["DCRenderKit"],
            path: "Tests/DCRenderKitTests",
            resources: [
                // Legacy kernels carry the pre-compiler-refactor
                // standalone `.metal` source for every pixel-local
                // built-in filter, renamed with a `DCRLegacy...`
                // prefix. They live in the test target (not the
                // SDK target) so the shipping binary never includes
                // them, and they serve as the parity reference for
                // the Phase-3 compute-backend tests. Deleted after
                // the Phase-7 final-verification gate per the
                // pipeline-compiler design doc §4.3.
                .process("LegacyKernels"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
