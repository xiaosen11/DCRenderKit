//
//  LoweringTests.swift
//  DCRenderKitTests
//
//  Exercises `Lowering.lower(_:source:)` — the Phase-1 translation
//  from `[AnyFilter]` to `PipelineGraph`. These tests do not dispatch
//  to the GPU: they examine the structure of the lowered IR so later
//  optimiser / codegen phases can rely on stable shape invariants.
//
//  See `docs/pipeline-compiler-design.md` §3.2 for invariants and
//  §10.1 for the Phase-1 test plan.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class LoweringTests: XCTestCase {

    // MARK: - Fixtures

    /// 1080-square source used by all lowering tests. Dimensions
    /// are large enough that SoftGlow's adaptive pyramid picks a
    /// non-trivial depth (log2(1080/135) = 3) but small enough to
    /// keep any downstream allocation cheap. `.rgba16Float` matches
    /// the SDK's default intermediate format; picking the matching
    /// format lets us assert Lowering-wide behaviour without a
    /// format-conversion channel.
    private var fixtureSource: TextureInfo {
        TextureInfo(width: 1080, height: 1080, pixelFormat: .rgba16Float)
    }

    /// Tiny overlay for `NormalBlendFilter`; the lowering tests
    /// inspect shape only and never dispatch, so the overlay's
    /// contents are irrelevant.
    private func makeDummyOverlay() -> MTLTexture {
        let device = MTLCreateSystemDefaultDevice()!
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1, height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        return device.makeTexture(descriptor: desc)!
    }

    /// Minimal identity 2³ LUT for `LUT3DFilter`; same rationale.
    private func makeIdentityLUT3D() throws -> LUT3DFilter {
        let identity2Cube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let data = identity2Cube.withUnsafeBufferPointer { Data(buffer: $0) }
        return try LUT3DFilter(cubeData: data, dimension: 2)
    }

    // MARK: - Empty / identity pipeline

    /// An empty chain produces no graph. Caller policy is to return
    /// the source texture unchanged.
    func testEmptyStepsProducesNil() {
        XCTAssertNil(Lowering.lower([], source: fixtureSource))
    }

    /// An all-multi chain whose filters short-circuit to empty
    /// `passes(input:)` produces no graph. Derivation: at default
    /// parameters, `HighlightShadowFilter(highlights: 0, shadows: 0)`
    /// returns `[]` from `passes(input:)` per its shader dead-zone.
    func testIdentityMultiPassChainProducesNil() {
        let steps: [AnyFilter] = [.multi(HighlightShadowFilter())]
        XCTAssertNil(Lowering.lower(steps, source: fixtureSource))
    }

    // MARK: - Single pixel-local filter

    /// Lowering a single pixel-local filter produces a one-node
    /// graph whose sole node reads `.source`, carries the filter's
    /// `FusionBody`, and is flagged final.
    func testSinglePixelLocalFilterLowers() throws {
        let steps: [AnyFilter] = [.single(ExposureFilter(exposure: 20))]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.totalAdditionalInputs, 0)
        let node = graph.nodes[0]
        XCTAssertEqual(node.id, 0)
        XCTAssertEqual(node.inputs, [.source])
        XCTAssertTrue(node.isFinal)
        XCTAssertEqual(graph.finalID, 0)

        guard case .pixelLocal(let body, _, _, let aux) = node.kind else {
            XCTFail("Expected .pixelLocal, got \(node.kind)")
            return
        }
        XCTAssertEqual(body.functionName, "DCRExposureBody")
        XCTAssertTrue(aux.isEmpty)
    }

    /// Sharpen lowers to a `.neighborRead` Node carrying the
    /// filter's declared radius.
    func testSingleNeighborReadFilterLowers() throws {
        let steps: [AnyFilter] = [.single(SharpenFilter(amount: 50))]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.nodes.count, 1)
        guard case .neighborRead(let body, _, let radius, _) = graph.nodes[0].kind else {
            XCTFail("Expected .neighborRead, got \(graph.nodes[0].kind)")
            return
        }
        XCTAssertEqual(body.functionName, "DCRSharpenBody")
        XCTAssertEqual(radius, 8)
    }

    /// LUT3D carries its LUT as an additional input. The lowered
    /// node's `additionalNodeInputs` should reference that slot
    /// through the graph-global `.additional(0)` ref.
    func testLUT3DFilterLowersWithAdditionalInput() throws {
        let filter = try makeIdentityLUT3D()
        let steps: [AnyFilter] = [.single(filter)]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.totalAdditionalInputs, 1)
        guard case .pixelLocal(_, _, _, let aux) = graph.nodes[0].kind else {
            XCTFail("Expected .pixelLocal")
            return
        }
        XCTAssertEqual(aux, [.additional(0)])
    }

    /// NormalBlend carries its overlay as an additional input. The
    /// lowered node should reference `.additional(0)`. A second
    /// filter with its own additional input (LUT3D) should land at
    /// `.additional(1)` — the offset accumulates across chain steps.
    func testChainWithTwoAdditionalInputsOffsetsCorrectly() throws {
        let overlay = makeDummyOverlay()
        let lut = try makeIdentityLUT3D()
        let steps: [AnyFilter] = [
            .single(NormalBlendFilter(overlay: overlay)),
            .single(lut),
        ]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertEqual(graph.totalAdditionalInputs, 2)

        // First filter (NormalBlend) gets .additional(0).
        guard case .pixelLocal(_, _, _, let aux0) = graph.nodes[0].kind else {
            XCTFail("Expected .pixelLocal at node 0")
            return
        }
        XCTAssertEqual(aux0, [.additional(0)])

        // Second filter (LUT3D) gets .additional(1) — the offset
        // accumulated past NormalBlend's single additional input.
        guard case .pixelLocal(_, _, _, let aux1) = graph.nodes[1].kind else {
            XCTFail("Expected .pixelLocal at node 1")
            return
        }
        XCTAssertEqual(aux1, [.additional(1)])
    }

    // MARK: - Multi-pass filter

    /// HighlightShadow at a non-zero slider produces its 5-pass DAG.
    /// Every pass becomes a `nativeCompute` Node; the final pass
    /// of the filter is the pipeline's final node.
    func testHighlightShadowLowersToFivePassChain() throws {
        let steps: [AnyFilter] = [
            .multi(HighlightShadowFilter(highlights: 50, shadows: 0))
        ]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.nodes.count, 5)
        for node in graph.nodes {
            guard case .nativeCompute = node.kind else {
                XCTFail("HS passes should lower to nativeCompute, got \(node.kind) on \(node.debugLabel)")
                return
            }
        }
        XCTAssertTrue(graph.nodes.last?.isFinal == true)
        XCTAssertEqual(graph.nodes.filter { $0.isFinal }.count, 1)
    }

    /// SoftGlow's adaptive pyramid depth scales with the source
    /// short-side. At 1080² the filter emits multiple passes; each
    /// of them should land in the graph.
    func testSoftGlowAdaptivePyramidLowersAllPasses() throws {
        let steps: [AnyFilter] = [.multi(SoftGlowFilter(strength: 40))]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertGreaterThan(graph.nodes.count, 1, "SoftGlow must emit a multi-pass DAG")
        XCTAssertTrue(graph.nodes.last?.isFinal == true)
        XCTAssertEqual(graph.nodes.filter { $0.isFinal }.count, 1)
    }

    // MARK: - Mixed chains

    /// A [single → multi → single] chain preserves chain-head flow:
    /// the multi-pass filter's first pass consumes the preceding
    /// single filter's output (`currentHead` at that step), and
    /// the trailing single filter's input is the multi filter's
    /// final pass output.
    func testMixedChainPreservesChainHeads() throws {
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .multi(HighlightShadowFilter(highlights: 30)),
            .single(SaturationFilter(saturation: 1.2)),
        ]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.totalAdditionalInputs, 0)
        XCTAssertGreaterThanOrEqual(graph.nodes.count, 7)   // 1 + 5 + 1

        // Node 0 = Exposure, reads .source.
        XCTAssertEqual(graph.nodes[0].inputs, [.source])
        XCTAssertEqual(graph.nodes[0].debugLabel, "ExposureFilter#0")

        // Node 1 = HS pass 1, reads chain head (.node(0)) as its
        // PassInput.source mapping.
        XCTAssertEqual(graph.nodes[1].inputs, [.node(0)])

        // Saturation Node (last) reads HS's final pass output.
        let sat = graph.nodes[graph.nodes.count - 1]
        XCTAssertEqual(sat.debugLabel, "SaturationFilter#2")
        // HS's final pass is emitted at nodes[graph.nodes.count - 2]
        // (the Saturation lives at -1). Assert Saturation's input
        // is a .node(_) referencing that index's id.
        let hsFinal = graph.nodes[graph.nodes.count - 2]
        XCTAssertEqual(sat.inputs, [.node(hsFinal.id)])
        XCTAssertTrue(sat.isFinal)
    }

    /// Realistic 8-filter edit chain (Exposure → Contrast → Blacks →
    /// Whites → HS → Clarity → Saturation → LUT3D). Verifies the
    /// lowered graph's invariants hold end-to-end for a chain that
    /// mirrors a typical user "full edit" preset.
    func testRealisticEightFilterChainLowers() throws {
        let lut = try makeIdentityLUT3D()
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 12, lumaMean: 0.5)),
            .single(BlacksFilter(blacks: 5)),
            .single(WhitesFilter(whites: -5)),
            .multi(HighlightShadowFilter(highlights: 20, shadows: -15)),
            .multi(ClarityFilter(intensity: 30)),
            .single(SaturationFilter(saturation: 1.1)),
            .single(lut),
        ]

        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))
        XCTAssertEqual(graph.totalAdditionalInputs, 1)  // just LUT's LUT
        XCTAssertEqual(graph.nodes.filter { $0.isFinal }.count, 1)
        XCTAssertEqual(graph.nodes.last?.debugLabel, "LUT3DFilter#7")
        XCTAssertTrue(graph.nodes.last?.isFinal == true)

        // The graph must validate — every invariant in §3.2 holds.
        XCTAssertNoThrow(try graph.validate())
    }

    // MARK: - Unsupported fusion body fallback

    /// A `FilterProtocol` conformer with default `.unsupported`
    /// `fusionBody` lowers to `.nativeCompute` referencing its
    /// standalone kernel name.
    func testUnsupportedFusionBodyFallsBackToNativeCompute() throws {
        struct OpaqueFilter: FilterProtocol {
            var modifier: ModifierEnum { .compute(kernel: "DCRLegacyCustomKernel") }
            static var fuseGroup: FuseGroup? { nil }
        }
        let steps: [AnyFilter] = [.single(OpaqueFilter())]
        let graph = try XCTUnwrap(Lowering.lower(steps, source: fixtureSource))

        XCTAssertEqual(graph.nodes.count, 1)
        guard case .nativeCompute(let kernelName, _, _) = graph.nodes[0].kind else {
            XCTFail("Expected .nativeCompute for unsupported fusionBody")
            return
        }
        XCTAssertEqual(kernelName, "DCRLegacyCustomKernel")
    }

    /// A filter with a non-compute modifier (render / blit / MPS)
    /// cannot be lowered in Phase 1. `lower(_:source:)` returns
    /// `nil` so the caller falls back to the source texture.
    func testNonComputeSinglePassFallsBack() {
        struct RenderOnlyFilter: FilterProtocol {
            var modifier: ModifierEnum {
                .render(vertex: "v", fragment: "f")
            }
            static var fuseGroup: FuseGroup? { nil }
        }
        let steps: [AnyFilter] = [.single(RenderOnlyFilter())]
        XCTAssertNil(Lowering.lower(steps, source: fixtureSource))
    }
}
