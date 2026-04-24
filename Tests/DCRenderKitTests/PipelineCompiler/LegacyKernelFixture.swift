//
//  LegacyKernelFixture.swift
//  DCRenderKitTests
//
//  Loads the test-target-only `.metal` sources under
//  `Tests/DCRenderKitTests/LegacyKernels/`, compiles each into its
//  own `MTLLibrary`, and registers them with
//  `ShaderLibrary.shared` so the `DCRLegacy<Name>Filter` kernels
//  can be resolved by subsequent tests.
//
//  The legacy kernels are byte-for-byte copies of the production
//  pixel-local filter shaders, renamed with a `DCRLegacy` prefix so
//  they do not collide with the production or compiler-generated
//  kernels. They serve as the parity reference for Phase-3 codegen
//  tests and will be deleted after the Phase-7 final-verification
//  gate — see `docs/pipeline-compiler-design.md` §4.3.
//
//  Registration is idempotent and thread-safe: the first test
//  (usually `LegacyKernelAvailabilityTests`) triggers
//  `registerIfNeeded()`, later tests are no-ops.
//

import Foundation
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
enum LegacyKernelFixture {

    // MARK: - Manifests

    /// The 12 legacy `.metal` filenames without extension, in
    /// declaration order. Order is not semantically meaningful —
    /// we register all 12 regardless.
    static let legacyMetalFiles: [String] = [
        "LegacyExposureFilter",
        "LegacyContrastFilter",
        "LegacyBlacksFilter",
        "LegacyWhitesFilter",
        "LegacySharpenFilter",
        "LegacySaturationFilter",
        "LegacyVibranceFilter",
        "LegacyWhiteBalanceFilter",
        "LegacyFilmGrainFilter",
        "LegacyCCDFilter",
        "LegacyLUT3DFilter",
        "LegacyNormalBlendFilter",
    ]

    /// Metal kernel function names the registration process exposes.
    /// Parity-reference tests assert each of these resolves via
    /// `ShaderLibrary.shared.function(named:)` after registration.
    ///
    /// Note: `NormalBlend` was originally named
    /// `DCRBlendNormalFilter` rather than `DCRNormalBlendFilter`;
    /// that word order is preserved to keep the kernel byte-equal
    /// to the production source.
    static let legacyKernelNames: [String] = [
        "DCRLegacyExposureFilter",
        "DCRLegacyContrastFilter",
        "DCRLegacyBlacksFilter",
        "DCRLegacyWhitesFilter",
        "DCRLegacySharpenFilter",
        "DCRLegacySaturationFilter",
        "DCRLegacyVibranceFilter",
        "DCRLegacyWhiteBalanceFilter",
        "DCRLegacyFilmGrainFilter",
        "DCRLegacyCCDFilter",
        "DCRLegacyLUT3DFilter",
        "DCRLegacyBlendNormalFilter",
    ]

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case metalDeviceUnavailable
        case metalFileMissing(String)
        case metalFileUnreadable(String, underlying: Swift.Error)
        case libraryCompileFailed(String, underlying: Swift.Error)

        var description: String {
            switch self {
            case .metalDeviceUnavailable:
                return "LegacyKernelFixture: no Metal device available"
            case .metalFileMissing(let name):
                return "LegacyKernelFixture: \(name).metal not found in test bundle"
            case .metalFileUnreadable(let name, let e):
                return "LegacyKernelFixture: failed to read \(name).metal — \(e)"
            case .libraryCompileFailed(let name, let e):
                return "LegacyKernelFixture: failed to compile \(name).metal — \(e)"
            }
        }
    }

    // MARK: - Registration

    private static let registrationQueue = DispatchQueue(
        label: "com.dcrenderkit.tests.legacy-kernel-fixture"
    )
    nonisolated(unsafe) private static var registered = false

    /// Register every legacy kernel library with
    /// `ShaderLibrary.shared`. Safe to call from any thread; runs
    /// its work exactly once across the life of the test-process.
    ///
    /// - Parameter device: Metal device to compile against. Defaults
    ///   to the system default. Tests running on a device-less CI
    ///   path throw `Error.metalDeviceUnavailable`; callers should
    ///   skip via `XCTSkip` when that surfaces.
    /// - Throws: `Error` detailing which step failed.
    static func registerIfNeeded(
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        try registrationQueue.sync {
            guard !registered else { return }
            guard let device else {
                throw Error.metalDeviceUnavailable
            }

            for baseName in legacyMetalFiles {
                guard let url = Bundle.module.url(
                    forResource: baseName,
                    withExtension: "metal"
                ) else {
                    throw Error.metalFileMissing(baseName)
                }

                let source: String
                do {
                    source = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw Error.metalFileUnreadable(baseName, underlying: error)
                }

                let library: MTLLibrary
                do {
                    library = try device.makeLibrary(source: source, options: nil)
                } catch {
                    throw Error.libraryCompileFailed(baseName, underlying: error)
                }

                ShaderLibrary.shared.register(library)
            }

            registered = true
        }
    }
}
