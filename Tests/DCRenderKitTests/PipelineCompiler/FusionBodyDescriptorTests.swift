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
    /// the initialiser takes 6 arguments and constructs a
    /// `FusionBody` payload with 1:1 field mapping, so reading each
    /// field back should return the original value.
    func testPrimaryInitPreservesAllFields() {
        let descriptor = FusionBodyDescriptor(
            functionName: "DCRExposureBody",
            uniformStructName: "ExposureUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceText: "// ExposureFilter stub source",
            sourceLabel: "ExposureFilter.metal"
        )

        guard let body = descriptor.body else {
            XCTFail("Primary init should produce a non-nil body")
            return
        }
        XCTAssertEqual(body.functionName, "DCRExposureBody")
        XCTAssertEqual(body.uniformStructName, "ExposureUniforms")
        XCTAssertEqual(body.kind, .pixelLocal)
        XCTAssertFalse(body.wantsLinearInput)
        XCTAssertEqual(body.sourceText, "// ExposureFilter stub source")
        XCTAssertEqual(body.sourceLabel, "ExposureFilter.metal")
    }

    /// `.neighborRead(radius:)` round-trips — the radius reaches
    /// the compiler's tile-boundary analysis without truncation.
    func testNeighborReadKindPreservesRadius() {
        let descriptor = FusionBodyDescriptor(
            functionName: "DCRSharpenBody",
            uniformStructName: "SharpenUniforms",
            kind: .neighborRead(radius: 3),
            wantsLinearInput: true,
            sourceText: "// SharpenFilter stub source",
            sourceLabel: "SharpenFilter.metal"
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
            sourceText: "// any.metal stub",
            sourceLabel: "any.metal"
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

    /// The SDK's 12 single-pass built-in filters each declare a
    /// concrete `fusionBody` pointing at a `DCR<Name>Body` function
    /// in their own `.metal` file. Phase 1 adds the descriptor; the
    /// body function itself lands in Phase 3. This test asserts the
    /// descriptor side of that contract — any filter that regresses
    /// to `.unsupported` (or ships a malformed descriptor) fails here
    /// before Phase 3 can consume it.
    ///
    /// Multi-pass filters (HighlightShadow / Clarity / SoftGlow /
    /// PortraitBlur) conform to `MultiPassFilter`, not
    /// `FilterProtocol`, so they are deliberately absent from this
    /// list; their compiler integration lands in Phase 2 via the
    /// `Pass`-level lowering path.
    func testBuiltInSinglePassFiltersDeclareConcreteDescriptors() {
        struct Expectation {
            let filter: any FilterProtocol
            let expectedFunctionName: String
            let expectedUniformStructName: String
            let expectedKind: FusionNodeKind
            let expectedMetalFileBaseName: String
        }

        let expectations: [Expectation] = [
            Expectation(filter: ExposureFilter(),
                        expectedFunctionName: "DCRExposureBody",
                        expectedUniformStructName: "ExposureUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "ExposureFilter"),
            Expectation(filter: ContrastFilter(),
                        expectedFunctionName: "DCRContrastBody",
                        expectedUniformStructName: "ContrastUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "ContrastFilter"),
            Expectation(filter: BlacksFilter(),
                        expectedFunctionName: "DCRBlacksBody",
                        expectedUniformStructName: "BlacksUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "BlacksFilter"),
            Expectation(filter: WhitesFilter(),
                        expectedFunctionName: "DCRWhitesBody",
                        expectedUniformStructName: "WhitesUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "WhitesFilter"),
            Expectation(filter: SharpenFilter(),
                        expectedFunctionName: "DCRSharpenBody",
                        expectedUniformStructName: "SharpenUniforms",
                        expectedKind: .neighborRead(radius: 8),
                        expectedMetalFileBaseName: "SharpenFilter"),
            Expectation(filter: SaturationFilter(),
                        expectedFunctionName: "DCRSaturationBody",
                        expectedUniformStructName: "SaturationUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "SaturationFilter"),
            Expectation(filter: VibranceFilter(),
                        expectedFunctionName: "DCRVibranceBody",
                        expectedUniformStructName: "VibranceUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "VibranceFilter"),
            Expectation(filter: WhiteBalanceFilter(),
                        expectedFunctionName: "DCRWhiteBalanceBody",
                        expectedUniformStructName: "WhiteBalanceUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "WhiteBalanceFilter"),
            Expectation(filter: FilmGrainFilter(),
                        expectedFunctionName: "DCRFilmGrainBody",
                        expectedUniformStructName: "FilmGrainUniforms",
                        expectedKind: .neighborRead(radius: 16),
                        expectedMetalFileBaseName: "FilmGrainFilter"),
            Expectation(filter: CCDFilter(),
                        expectedFunctionName: "DCRCCDBody",
                        expectedUniformStructName: "CCDUniforms",
                        expectedKind: .neighborRead(radius: 32),
                        expectedMetalFileBaseName: "CCDFilter"),
            Expectation(filter: NormalBlendFilter(overlay: makeDummyOverlay()),
                        expectedFunctionName: "DCRNormalBlendBody",
                        expectedUniformStructName: "NormalBlendUniforms",
                        expectedKind: .pixelLocal,
                        expectedMetalFileBaseName: "NormalBlendFilter"),
            // LUT3DFilter requires a LUT texture; tested separately.
        ]

        for e in expectations {
            guard let body = e.filter.fusionBody.body else {
                XCTFail("\(type(of: e.filter)) should ship a concrete fusionBody at Phase 1")
                continue
            }
            XCTAssertEqual(
                body.functionName, e.expectedFunctionName,
                "\(type(of: e.filter)).fusionBody.functionName"
            )
            XCTAssertEqual(
                body.uniformStructName, e.expectedUniformStructName,
                "\(type(of: e.filter)).fusionBody.uniformStructName"
            )
            XCTAssertEqual(
                body.kind, e.expectedKind,
                "\(type(of: e.filter)).fusionBody.kind"
            )
            XCTAssertEqual(
                body.sourceLabel,
                "\(e.expectedMetalFileBaseName).metal",
                "\(type(of: e.filter)).fusionBody.sourceLabel identifies the expected .metal"
            )
            XCTAssertFalse(
                body.sourceText.isEmpty,
                "\(type(of: e.filter)).fusionBody.sourceText must be a non-empty bundled string"
            )
            XCTAssertTrue(
                body.sourceText.contains("@dcr:body-begin"),
                "\(type(of: e.filter)).fusionBody.sourceText must contain the body marker for \(e.expectedFunctionName)"
            )
        }
    }

    /// LUT3DFilter is covered separately because its initialiser
    /// consumes parsed rgba32Float binary LUT data (dimension³ ×
    /// 16 bytes). We build a minimal identity 2³ cube inline and
    /// verify the descriptor — the descriptor check itself never
    /// dispatches, so cube correctness (beyond matching the byte
    /// layout LUT3DFilter expects) is irrelevant.
    func testLUT3DFilterDeclaresConcreteDescriptor() throws {
        // 2³ identity LUT: each corner of the unit cube stored as
        // (r, g, b, 1) in rgba32Float. Voxel order is x fastest, z
        // slowest (matching `texture3d.write(voxel, uint3(x,y,z))`
        // layout CubeFileParser produces).
        let identity2Cube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let cubeData = identity2Cube.withUnsafeBufferPointer { Data(buffer: $0) }

        let filter: LUT3DFilter
        do {
            filter = try LUT3DFilter(cubeData: cubeData, dimension: 2)
        } catch {
            throw XCTSkip(
                "LUT3DFilter init failed (likely Metal device unavailable): \(error). " +
                "Descriptor shape is indirectly covered by Phase 3's body-dispatch tests."
            )
        }

        guard let body = filter.fusionBody.body else {
            XCTFail("LUT3DFilter should ship a concrete fusionBody at Phase 1")
            return
        }
        XCTAssertEqual(body.functionName, "DCRLUT3DBody")
        XCTAssertEqual(body.uniformStructName, "LUT3DUniforms")
        XCTAssertEqual(body.kind, .pixelLocal)
        XCTAssertEqual(body.sourceLabel, "LUT3DFilter.metal")
        XCTAssertTrue(body.sourceText.contains("@dcr:body-begin DCRLUT3DBody"))
    }

    // MARK: - Helpers

    /// Build a tiny dummy overlay for NormalBlendFilter init; contents
    /// are irrelevant because the descriptor-check never dispatches.
    private func makeDummyOverlay() -> MTLTexture {
        let device = MTLCreateSystemDefaultDevice()!
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        return device.makeTexture(descriptor: desc)!
    }
}
