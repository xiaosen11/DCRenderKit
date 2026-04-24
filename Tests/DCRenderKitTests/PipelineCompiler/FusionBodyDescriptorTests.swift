//
//  FusionBodyDescriptorTests.swift
//  DCRenderKitTests
//
//  Verifies the Phase-1 public-API additions introduced by the
//  pipeline-compiler refactor (see docs/pipeline-compiler-design.md §4,
//  §9). The descriptor type itself is trivial storage, but three
//  behaviours need explicit contract tests:
//
//    - The primary initialiser preserves every field (no silent copy
//      conversion, no accidental normalisation).
//    - The `.unsupported` sentinel is structurally distinct from any
//      real descriptor so downstream equality / switch checks don't
//      accidentally match.
//    - Every existing `FilterProtocol` conformer — SDK built-in or
//      third-party — inherits the `.unsupported` default without
//      having to explicitly override, preserving backward
//      compatibility. Concrete descriptors for the SDK's 16 built-in
//      filters land in a later Phase-1 step and will add their own
//      targeted tests.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class FusionBodyDescriptorTests: XCTestCase {

    // MARK: - Constructor round-trip

    /// The primary initialiser stores every supplied field. Derivation:
    /// the initialiser takes 5 arguments and constructs a
    /// `FusionBody` payload with 1:1 field mapping, so reading each
    /// field back should return the original value.
    func testPrimaryInitPreservesAllFields() {
        let url = URL(fileURLWithPath: "/tmp/ExposureFilter.metal")
        let descriptor = FusionBodyDescriptor(
            functionName: "DCRExposureBody",
            uniformStructName: "ExposureUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceMetalFile: url
        )

        guard let body = descriptor.body else {
            XCTFail("Primary init should produce a non-nil body")
            return
        }
        XCTAssertEqual(body.functionName, "DCRExposureBody")
        XCTAssertEqual(body.uniformStructName, "ExposureUniforms")
        XCTAssertEqual(body.kind, .pixelLocal)
        XCTAssertFalse(body.wantsLinearInput)
        XCTAssertEqual(body.sourceMetalFile, url)
    }

    /// `.neighborRead(radius:)` round-trips — the radius reaches
    /// the compiler's tile-boundary analysis without truncation.
    func testNeighborReadKindPreservesRadius() {
        let descriptor = FusionBodyDescriptor(
            functionName: "DCRSharpenBody",
            uniformStructName: "SharpenUniforms",
            kind: .neighborRead(radius: 3),
            wantsLinearInput: true,
            sourceMetalFile: URL(fileURLWithPath: "/tmp/SharpenFilter.metal")
        )

        guard case .neighborRead(let radius) = descriptor.body?.kind else {
            XCTFail("Expected .neighborRead kind to survive round-trip")
            return
        }
        XCTAssertEqual(radius, 3)
    }

    // MARK: - Unsupported sentinel

    /// `.unsupported` must carry a nil body payload — this is the
    /// signal the optimiser uses to skip the filter for fusion.
    func testUnsupportedSentinelHasNilBody() {
        let sentinel = FusionBodyDescriptor.unsupported
        XCTAssertNil(sentinel.body, ".unsupported must carry nil body")
    }

    /// `.unsupported` is structurally distinct from any real
    /// descriptor: a concrete descriptor always has a non-nil body,
    /// so the optimiser's "is this filter fusable" check reduces to
    /// `body != nil` without needing kind-specific matching.
    func testUnsupportedSentinelDistinguishesFromRealDescriptor() {
        let real = FusionBodyDescriptor(
            functionName: "DCRAnyBody",
            uniformStructName: "AnyUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceMetalFile: URL(fileURLWithPath: "/tmp/any.metal")
        )
        XCTAssertNotNil(real.body)
        XCTAssertNil(FusionBodyDescriptor.unsupported.body)
    }

    // MARK: - FilterProtocol default

    /// A `FilterProtocol` conformer that doesn't override `fusionBody`
    /// inherits `.unsupported`. Legacy third-party filters therefore
    /// compile without adaptation. Exercised via a minimal in-test
    /// conformer whose body is pure Swift (no Metal dispatch).
    func testFilterProtocolDefaultIsUnsupported() {
        struct LegacyStub: FilterProtocol {
            var modifier: ModifierEnum { .compute(kernel: "noop") }
            static var fuseGroup: FuseGroup? { nil }
        }
        let stub = LegacyStub()
        XCTAssertNil(
            stub.fusionBody.body,
            "A FilterProtocol conformer that doesn't override fusionBody must inherit .unsupported"
        )
    }

    /// Every SDK built-in filter inherits the default at Phase 1 (each
    /// one's concrete descriptor lands in a later Phase 1 step, and
    /// the targeted test for that step will flip this expectation).
    /// Asserting the current state prevents a filter from silently
    /// half-migrating: if a future commit adds a non-default
    /// `fusionBody` to ExposureFilter but forgets to land the
    /// corresponding body function in the `.metal` file, this test
    /// will fail immediately rather than at runtime.
    func testBuiltInFiltersCurrentlyUnsupported() {
        // Snapshot of current state at Phase 1 step 1. Remove entries
        // from this array as each filter adopts a concrete descriptor
        // in follow-up commits.
        let phaseOneStepOneExpectedUnsupported: [any FilterProtocol] = [
            ExposureFilter(),
            ContrastFilter(),
            BlacksFilter(),
            WhitesFilter(),
            SaturationFilter(),
            VibranceFilter(),
            WhiteBalanceFilter(),
            SharpenFilter(),
        ]
        for filter in phaseOneStepOneExpectedUnsupported {
            XCTAssertNil(
                filter.fusionBody.body,
                "\(type(of: filter)) should still be .unsupported at Phase 1 step 1"
            )
        }
    }
}
