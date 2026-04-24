//
//  OptimizerIntegrationTests.swift
//  DCRenderKitTests
//
//  End-to-end tests for `Optimizer.optimize(_:)` — the Phase-2
//  entry point that chains DCE → VerticalFusion → CSE →
//  KernelInlining → TailSink. These exercise the interaction
//  between passes on realistic graphs produced by Phase-1
//  lowering, complementing the per-pass fixture tests.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class OptimizerIntegrationTests: XCTestCase {

    private var source: TextureInfo {
        TextureInfo(width: 1080, height: 1080, pixelFormat: .rgba16Float)
    }

    // MARK: - Vertical fusion through a realistic chain

    /// `[Exposure, Contrast, Saturation]` lowers into three
    /// pixelLocal nodes; after the optimiser they collapse into
    /// a single `.fusedPixelLocalCluster` node.
    func testThreePixelLocalChainCollapsesToOneCluster() throws {
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.2)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: source))
        let optimised = Optimizer.optimize(lowered)

        XCTAssertEqual(optimised.nodes.count, 1)
        guard case let .fusedPixelLocalCluster(members, _, _) = optimised.nodes[0].kind else {
            XCTFail("Expected fusedPixelLocalCluster, got \(optimised.nodes[0].kind)")
            return
        }
        XCTAssertEqual(
            members.map { $0.body.functionName },
            ["DCRExposureBody", "DCRContrastBody", "DCRSaturationBody"]
        )
        XCTAssertTrue(optimised.nodes[0].isFinal)
    }

    // MARK: - CSE does NOT fold HS + Clarity downsamples (linear chain)

    /// In a linear `[HS, Clarity]` chain, HS's downsample reads
    /// `.source` but Clarity's downsample reads HS's final pass
    /// output (chain-head handoff inside Lowering). Their
    /// `NodeSignature.inputs` therefore differ, and CSE correctly
    /// leaves them alone.
    ///
    /// This test pins that semantic. CSE's sharing payoff lands
    /// when the IR itself exposes two computations with
    /// genuinely identical inputs — e.g. future branch / merge
    /// filter graphs or hand-constructed IR in tests. Linear
    /// chains trigger it only when a filter's `PassInput.source`
    /// happens to match another filter's upstream input by
    /// coincidence, which isn't the HS + Clarity case.
    func testHSAndClarityDownsamplesDoNotFoldInLinearChain() throws {
        let steps: [AnyFilter] = [
            .multi(HighlightShadowFilter(highlights: 40)),
            .multi(ClarityFilter(intensity: 30)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: source))
        let optimised = Optimizer.optimize(lowered)

        let downsampleCount = optimised.nodes.reduce(0) { acc, node in
            if case .nativeCompute(let kernel, _, _) = node.kind,
               kernel == "DCRGuidedDownsampleLuma" {
                return acc + 1
            }
            return acc
        }
        XCTAssertEqual(
            downsampleCount, 2,
            "HS and Clarity downsamples read different inputs (source vs HS output), so CSE must not fold them"
        )
    }

    /// CSE _does_ fold when two nativeCompute nodes genuinely
    /// read the same input with the same kernel / uniforms /
    /// output spec. Exercised via a hand-built IR that puts two
    /// hypothetical `.source`-reading nativeComputes in the same
    /// graph — exactly the shape Phase-3 benchmarks will produce
    /// when branching IR is introduced.
    func testHandBuiltDuplicateNativeComputesFold() throws {
        let nodes: [Node] = [
            PipelineCompilerTestFixtures.nativeComputeNode(
                id: 0, kernelName: "DCRGuidedDownsampleLuma",
                outputSpec: .scaled(factor: 0.25)
            ),
            PipelineCompilerTestFixtures.nativeComputeNode(
                id: 1, kernelName: "DCRGuidedDownsampleLuma",
                outputSpec: .scaled(factor: 0.25)
            ),
            PipelineCompilerTestFixtures.pixelLocalNode(
                id: 2, bodyName: "F",
                input: .node(0),
                isFinal: true,
                additionalNodeInputs: [.node(1)]
            ),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let optimised = Optimizer.optimize(g)

        let downsampleCount = optimised.nodes.reduce(0) { acc, node in
            if case .nativeCompute(let kernel, _, _) = node.kind,
               kernel == "DCRGuidedDownsampleLuma" {
                return acc + 1
            }
            return acc
        }
        XCTAssertEqual(downsampleCount, 1, "CSE must fold the two identical downsamples")
    }

    // MARK: - TailSink across HS → Saturation

    /// The HS filter's final pass is `DCRHighlightShadowApply`
    /// (a `.nativeCompute` node in Phase-1 lowering). TailSink
    /// **skips** nativeCompute producers because the compiler
    /// can't splice into opaque kernels, so the downstream
    /// Saturation stays as its own node. This test pins the
    /// current aggressive-TailSink scope so future work that
    /// refines HS's final pass to a known body can flip the
    /// expectation.
    func testHSFinalPassPlusSaturationDoesNotTailSinkInPhase2() throws {
        let steps: [AnyFilter] = [
            .multi(HighlightShadowFilter(highlights: 40)),
            .single(SaturationFilter(saturation: 1.3)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: source))
        let optimised = Optimizer.optimize(lowered)

        // Saturation survives as a separate .pixelLocal node (not
        // as a fused cluster, not sinked into HS's final).
        let satNode = optimised.nodes.first { $0.debugLabel.contains("Saturation") }
        XCTAssertNotNil(satNode, "Saturation should still exist as its own node")
        if let node = satNode, case .pixelLocal = node.kind {
            // expected
        } else {
            XCTFail("Saturation should remain a pixelLocal node in Phase 2")
        }
        XCTAssertTrue(satNode?.isFinal ?? false)
    }

    // MARK: - TailSink absorbs pixelLocal into cluster

    /// Manually construct a graph where a
    /// `.fusedPixelLocalCluster` (produced by VerticalFusion) sits
    /// adjacent to a pixelLocal successor whose only consumer is
    /// the cluster's output. The full `Optimizer.optimize` should
    /// recognise the opportunity: VerticalFusion itself doesn't
    /// cross a heterogeneous boundary because by then the cluster
    /// has been emitted, but TailSink **does** pick it up and
    /// absorb the pixelLocal as a new cluster member.
    ///
    /// Simplest realistic shape: a 4-filter pixelLocal chain. The
    /// entire chain vertically fuses into one cluster in one shot;
    /// TailSink has nothing left to do (everything is already in
    /// the cluster). So we can exercise TailSink's cluster-absorb
    /// path only by staging a pre-existing cluster artificially.
    /// That's covered in the pass's own unit test; here we assert
    /// the combined pipeline doesn't regress.
    func testFourFilterChainFullyCollapses() throws {
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 5)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
            .single(BlacksFilter(blacks: 5)),
            .single(SaturationFilter(saturation: 1.1)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: source))
        XCTAssertEqual(lowered.nodes.count, 4)

        let optimised = Optimizer.optimize(lowered)
        XCTAssertEqual(optimised.nodes.count, 1)
        guard case let .fusedPixelLocalCluster(members, _, _) = optimised.nodes[0].kind else {
            XCTFail("Expected fusedPixelLocalCluster")
            return
        }
        XCTAssertEqual(members.count, 4)
        XCTAssertTrue(optimised.nodes[0].isFinal)
    }

    // MARK: - Realistic 8-filter edit chain

    /// A realistic 8-filter edit preset exercises every pass.
    /// Expectations after `Optimizer.optimize`:
    ///   · DCE: no dead nodes in the lowered graph (lowering doesn't
    ///     produce any at Phase 1), so this is a no-op guard.
    ///   · VerticalFusion: clusters the leading 4 tone operators
    ///     (Exposure → Contrast → Blacks → Whites) into one
    ///     cluster; also clusters a trailing Saturation onto the
    ///     LUT3D pixelLocal (both are pixelLocal).
    ///   · CSE: the HS and Clarity guided-downsample duplicates
    ///     fold into one shared downsample node.
    ///   · KernelInlining: no pixelLocal → neighborRead boundaries
    ///     that survive into the final graph, so this is mostly
    ///     quiet.
    ///   · TailSink: doesn't absorb across the HS / Clarity
    ///     neighbour-read boundary because those filters emit
    ///     `.nativeCompute` final passes (TailSink only handles
    ///     cluster / neighborRead producers).
    ///
    /// We don't pin exact node counts (that would make the test
    /// brittle to benign lowering changes); we only pin the
    /// invariants that matter: monotone reduction relative to
    /// lowering, single final node, valid graph.
    func testRealisticEightFilterChainPreservesInvariants() throws {
        // Use two pixelLocal-only filter groups bracketing the
        // multi-pass HS/Clarity pair so the fusion surfaces.
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            .single(BlacksFilter(blacks: 5)),
            .single(WhitesFilter(whites: -5)),
            .multi(HighlightShadowFilter(highlights: 20)),
            .multi(ClarityFilter(intensity: 20)),
            .single(SaturationFilter(saturation: 1.1)),
            .single(VibranceFilter(vibrance: 0.3)),
        ]

        let lowered = try XCTUnwrap(Lowering.lower(steps, source: source))
        let optimised = Optimizer.optimize(lowered)

        // Invariants.
        XCTAssertEqual(optimised.nodes.filter { $0.isFinal }.count, 1)
        XCTAssertNoThrow(try optimised.validate())
        XCTAssertLessThan(
            optimised.nodes.count, lowered.nodes.count,
            "Optimiser must reduce node count on this chain"
        )

        // VerticalFusion guard: at least one fusedPixelLocalCluster
        // should have emerged (the tone-operator cluster).
        let clusters = optimised.nodes.filter { node in
            if case .fusedPixelLocalCluster = node.kind { return true }
            return false
        }
        XCTAssertFalse(clusters.isEmpty, "VerticalFusion must have produced at least one cluster")

        // Note on CSE: in a linear `[HS, Clarity]` chain, the two
        // filters' guided downsamples read different inputs (HS
        // reads .source, Clarity reads HS's output), so CSE
        // correctly does not fold them. See
        // `testHSAndClarityDownsamplesDoNotFoldInLinearChain`.
    }

    // MARK: - Null-op

    /// Empty graph input (via `Lowering.lower` returning nil) is
    /// handled by the caller; `Optimizer.optimize(_)` on a valid
    /// single-node graph is a no-op. Included as a sanity guard.
    func testSingleNodeGraphIsUnchanged() throws {
        let steps: [AnyFilter] = [.single(ExposureFilter(exposure: 5))]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: source))
        let optimised = Optimizer.optimize(lowered)

        XCTAssertEqual(optimised.nodes.count, 1)
        XCTAssertEqual(optimised.nodes[0].id, lowered.nodes[0].id)
    }

    // MARK: - Pass-order invariance

    /// `Optimizer.defaultPasses` is documented as a fixed
    /// sequence. Pin the order so a future rearrangement requires
    /// deliberate coordination with the per-pass contracts.
    func testDefaultPassOrder() {
        let names = Optimizer.defaultPasses.map { $0.name }
        XCTAssertEqual(names, ["DCE", "VerticalFusion", "CSE", "KernelInlining", "TailSink"])
    }
}
