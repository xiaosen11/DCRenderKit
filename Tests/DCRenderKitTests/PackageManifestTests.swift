//
//  PackageManifestTests.swift
//  DCRenderKitTests
//
//  Regression guards on the SwiftPM manifest itself. These tests read
//  `Package.swift` as a source file and assert the constraints we
//  rely on being true — most importantly, the zero-external-dependency
//  invariant. A caller that adds a `.package(url: ...)` dependency will
//  trip this guard on the next `swift test`.
//

import XCTest

/// Regression guards on `Package.swift`.
///
/// The manifest is checked as text rather than through a compiled
/// `Package` object because the manifest API is not available to the
/// test target at runtime. Reading the source string keeps the test
/// cheap and independent of SwiftPM internals.
final class PackageManifestTests: XCTestCase {

    // MARK: - #73: Zero external dependencies

    /// DCRenderKit ships with **no external dependencies**. The value
    /// proposition of the SDK is "Metal + system frameworks, nothing
    /// else to vend through your app's SBOM". Any `.package(url: ...)`
    /// entry in `Package.swift.dependencies` breaks that.
    ///
    /// We search the manifest source for `.package(` — the syntax
    /// SwiftPM requires for every external dependency form
    /// (`.package(url:from:)`, `.package(name:path:)`, etc.). If the
    /// substring appears anywhere in the manifest, something was
    /// added that shouldn't be there.
    ///
    /// The manifest's existing comments explicitly enumerate the
    /// system frameworks used ("Metal, MetalKit, CoreImage optional,
    /// Vision optional, MetalPerformanceShaders optional") without
    /// using the `.package(` token, so this guard has no false
    /// positives against the current file.
    func testPackageHasNoExternalDependencies() throws {
        let manifest = try Self.readPackageManifest()

        XCTAssertFalse(
            manifest.contains(".package("),
            """
            DCRenderKit must keep `Package.swift.dependencies` empty. \
            The manifest contains a `.package(` invocation — an external \
            dependency was added. This breaks the SDK's zero-dependency \
            contract (#73; the repo root's TODO.md and CLAUDE.md cover the rules). \
            Either remove the dependency, or explicitly amend this test \
            and the zero-dependency claim in the docs before merging.
            """
        )
    }

    // MARK: - Helpers

    /// Resolve and read `Package.swift` from the repository root.
    ///
    /// Uses `#filePath` (not `#file` — which is an alias for `#fileID`
    /// in Swift 6 and resolves to a module-relative path, not an
    /// absolute one) to anchor to the test source location, then
    /// walks up to the repository root. SwiftPM always runs tests
    /// with the checkout intact, so the file is expected to exist;
    /// if it doesn't, the test environment is so unusual that skipping
    /// is the right outcome.
    private static func readPackageManifest(_ filePath: StaticString = #filePath) throws -> String {
        let testFileURL = URL(fileURLWithPath: String(describing: filePath))
        let manifestURL = testFileURL
            .deletingLastPathComponent()  // Tests/DCRenderKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo root>
            .appendingPathComponent("Package.swift")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Package.swift not found at \(manifestURL.path)")
        }
        return try String(contentsOf: manifestURL, encoding: .utf8)
    }
}
