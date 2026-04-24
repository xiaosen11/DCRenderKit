//
//  LegacyKernelAvailabilityTests.swift
//  DCRenderKitTests
//
//  Exercises the bundling + registration path for the 12 legacy
//  kernel `.metal` files the Phase-1 refactor copies into the test
//  target. These are the parity reference for Phase-3 compute-
//  backend tests; if any of them fail to compile or resolve, the
//  entire compiler-refactor verification story becomes unusable,
//  so this test file runs early and reports loudly.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class LegacyKernelAvailabilityTests: XCTestCase {

    override func setUpWithError() throws {
        // Registration is idempotent; calling per test is cheap
        // after the first invocation and keeps ordering safe if
        // another test file runs first.
        do {
            try LegacyKernelFixture.registerIfNeeded()
        } catch LegacyKernelFixture.Error.metalDeviceUnavailable {
            throw XCTSkip("Metal device unavailable in this environment")
        }
    }

    /// Every declared legacy `.metal` file must be bundled with the
    /// test target. A missing file surfaces as the registration
    /// helper's `metalFileMissing` error; that would mean
    /// `Package.swift` `resources:` rule regressed or the file was
    /// deleted prematurely.
    func testAllLegacyMetalFilesArePresentInTestBundle() {
        for baseName in LegacyKernelFixture.legacyMetalFiles {
            let url = Bundle.module.url(
                forResource: baseName,
                withExtension: "metal"
            )
            XCTAssertNotNil(
                url,
                "Test bundle is missing \(baseName).metal — see Package.swift testTarget resources: .process(\"LegacyKernels\")"
            )
        }
    }

    /// Every legacy kernel name must resolve via
    /// `ShaderLibrary.shared.function(named:)` after registration.
    /// Resolution traverses every registered library, so a missing
    /// function here means either:
    ///   (a) the corresponding `.metal` file failed to compile
    ///       (the `setUpWithError` hook would throw in that case,
    ///       so we never reach this test),
    ///   (b) the kernel name in the `.metal` source drifted from
    ///       the manifest in `LegacyKernelFixture.legacyKernelNames`.
    func testAllLegacyKernelNamesResolve() throws {
        for kernelName in LegacyKernelFixture.legacyKernelNames {
            XCTAssertNoThrow(
                try ShaderLibrary.shared.function(named: kernelName),
                "ShaderLibrary should resolve \(kernelName) after legacy-kernel registration"
            )
        }
    }

    /// The number of `.metal` files must equal the number of
    /// kernel names — sanity check that prevents a future commit
    /// from adding a file without its matching kernel (or vice
    /// versa) and regressing the parity coverage. 12 is the target
    /// across the single-pass filter set.
    func testManifestCountsAlign() {
        XCTAssertEqual(
            LegacyKernelFixture.legacyMetalFiles.count,
            LegacyKernelFixture.legacyKernelNames.count,
            "Legacy kernel manifests drifted"
        )
        XCTAssertEqual(
            LegacyKernelFixture.legacyMetalFiles.count,
            12,
            "Phase-1 expects 12 legacy kernels (one per single-pass pixel-local filter)"
        )
    }

    /// Invoking `registerIfNeeded` twice must not double-register
    /// or crash. The second call is expected to be a no-op; this
    /// test just confirms the helper's idempotence contract.
    func testRegisterIfNeededIsIdempotent() throws {
        XCTAssertNoThrow(try LegacyKernelFixture.registerIfNeeded())
        XCTAssertNoThrow(try LegacyKernelFixture.registerIfNeeded())
    }
}
