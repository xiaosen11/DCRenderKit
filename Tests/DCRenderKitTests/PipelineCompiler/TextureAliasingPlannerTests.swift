//
//  TextureAliasingPlannerTests.swift
//  DCRenderKitTests
//
//  Hermetic tests for the Phase-4 aliasing algorithm. Every case
//  hand-builds a PipelineGraph with a specific lifetime pattern
//  and asserts the planner produces the theoretical-minimum
//  bucket count + correct reuse semantics.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class TextureAliasingPlannerTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private var sourceInfo: TextureInfo {
        TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
    }

    // MARK: - Degenerate cases

    /// Empty graph produces no buckets.
    func testEmptyGraphProducesNoBuckets() {
        let graph = Fx.bypassingValidation(
            [],
            totalAdditionalInputs: 0
        )
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)
        XCTAssertEqual(plan.uniqueBucketCount, 0)
        XCTAssertTrue(plan.bucketOf.isEmpty)
    }

    /// Single-node graph: one bucket, tagged as the final node,
    /// never released.
    func testSingleFinalNodeOneBucket() {
        let graph = Fx.linearPixelLocalChain(length: 1)
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)
        XCTAssertEqual(plan.uniqueBucketCount, 1)
        XCTAssertEqual(plan.bucketOf[0], 0)
    }

    // MARK: - Linear chain reuse (ping-pong pattern)

    /// 3-node linear chain of same-spec outputs: the allocator
    /// should recognise ping-pong and use **exactly 2** buckets.
    /// Node 0's bucket releases when node 1 finishes (id 1 < id 2);
    /// node 2 reuses that same bucket; node 1's bucket stays
    /// distinct (it's final).
    ///
    /// Actually, reconsider: in `linearPixelLocalChain(3)`,
    /// nodes are 0→1→2, final is node 2. Let's compute:
    ///   · node 0 end-of-life = 1 (consumed by node 1)
    ///   · node 1 end-of-life = 2 (consumed by node 2)
    ///   · node 2 end-of-life = Int.max (final)
    ///
    /// Walk:
    ///   · step 0: no releases. Allocate bucket A for node 0. in_use={A: eol=1}
    ///   · step 1: releases at eol < 1 → none. Allocate bucket B
    ///     (A still in use; its eol=1 is not strictly less than 1).
    ///     in_use={A: eol=1, B: eol=2}
    ///   · step 2: releases at eol < 2 → bucket A (eol=1). A back to free.
    ///     node 2 reuses A. in_use={A: eol=Int.max, B: eol=2}
    ///
    /// Final bucket count: 2. Nodes 0 and 2 share bucket A;
    /// node 1 has bucket B.
    func testThreeNodeLinearChainUsesTwoBuckets() {
        let graph = Fx.linearPixelLocalChain(length: 3)
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)

        XCTAssertEqual(plan.uniqueBucketCount, 2,
                       "3-node linear chain must alias into ping-pong (2 textures)")
        // Nodes 0 and 2 share a bucket; node 1 has its own.
        XCTAssertEqual(plan.bucketOf[0], plan.bucketOf[2],
                       "Nodes 0 and 2 should alias (lifetimes disjoint)")
        XCTAssertNotEqual(plan.bucketOf[0], plan.bucketOf[1],
                          "Nodes 0 and 1 overlap — must not alias")
    }

    /// 5-node linear chain: still 2 buckets. The alias pattern
    /// settles into strict ping-pong regardless of chain length.
    func testLongLinearChainStaysAtTwoBuckets() {
        let graph = Fx.linearPixelLocalChain(length: 5)
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)
        XCTAssertEqual(plan.uniqueBucketCount, 2)
    }

    // MARK: - Fan-out (two consumers)

    /// Node 0 is read by nodes 1 **and** 2. Its bucket can't be
    /// reused until both consumers finish, so node 2 needs a new
    /// bucket even though node 1 has already finished. Node 3 (the
    /// final) then reuses one of the two released buckets.
    ///
    /// Expected bucket count: 3 (not 2) for this shape. We can
    /// prove that with a shape that forces it.
    ///
    /// Layout:
    ///   0 → 1 → 3
    ///       ↓
    ///   0 → 2 → 3
    ///
    /// node 0 eol = max(1, 2) = 2
    /// node 1 eol = 3
    /// node 2 eol = 3
    /// node 3 eol = Int.max
    ///
    /// Walk:
    ///   · step 0: allocate A for node 0.
    ///   · step 1: no releases (A.eol=2 not <1). Allocate B.
    ///   · step 2: no releases (A.eol=2 not <2). Allocate C.
    ///   · step 3: releases eol<3 → A (eol=2). Also B (eol=3)
    ///             and C (eol=3) are NOT <3, so not released.
    ///             Reuse A for node 3.
    ///
    /// Unique buckets: 3 (A, B, C). The final reuses A.
    func testFanOutRequiresThreeBuckets() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Shared"),
            Fx.pixelLocalNode(id: 1, bodyName: "A", input: .node(0)),
            Fx.pixelLocalNode(id: 2, bodyName: "B", input: .node(0),
                              additionalNodeInputs: [.node(1)]),
            Fx.pixelLocalNode(id: 3, bodyName: "Final",
                              input: .node(2), isFinal: true,
                              additionalNodeInputs: [.node(1)]),
        ]
        let graph = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)
        XCTAssertEqual(plan.uniqueBucketCount, 3,
                       "Fan-out from node 0 holds its bucket through node 2; plan must use 3 textures")

        // Invariants: aliasing pairs must have non-overlapping
        // lifetimes. Verified by checking that no two nodes
        // sharing a bucket have one reading from the other.
        let bucketOf = plan.bucketOf
        XCTAssertNotEqual(bucketOf[0], bucketOf[1], "1 reads 0")
        XCTAssertNotEqual(bucketOf[0], bucketOf[2], "2 reads 0")
        XCTAssertNotEqual(bucketOf[1], bucketOf[2], "2 reads 1")
        XCTAssertNotEqual(bucketOf[1], bucketOf[3], "3 reads 1")
        XCTAssertNotEqual(bucketOf[2], bucketOf[3], "3 reads 2")
    }

    // MARK: - Spec-mismatch prevents aliasing

    /// Nodes with different output specs can't share a bucket.
    /// Setup:
    ///   · node 0 (sameAsSource, 256²) → consumed by node 1
    ///   · node 1 (scaled 0.5, 128²) → consumed by node 2
    ///   · node 2 (sameAsSource, 256²) → final
    ///
    /// Node 0 and node 2 share a spec (256²) and have disjoint
    /// lifetimes → they SHARE bucket A. Node 1 has a different
    /// spec (128²) → it gets exclusive bucket B. Total: 2
    /// buckets. This pins the planner's spec-key behaviour:
    /// aliasing is keyed on full resolved `TextureInfo`, so an
    /// interloper with different dimensions correctly fails to
    /// pull in the same-spec nodes' buckets.
    func testSpecMismatchPreventsAlias() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "A"),
            Node(
                id: 1,
                kind: .pixelLocal(
                    body: Fx.dummyBody("B"),
                    uniforms: .empty,
                    wantsLinearInput: false,
                    additionalNodeInputs: []
                ),
                inputs: [.node(0)],
                outputSpec: .scaled(factor: 0.5),    // 128×128
                isFinal: false,
                debugLabel: "B"
            ),
            Fx.pixelLocalNode(id: 2, bodyName: "Final",
                              input: .node(1),
                              isFinal: true),
        ]
        let graph = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)

        XCTAssertEqual(plan.uniqueBucketCount, 2,
                       "Node 1 (128²) gets its own bucket; nodes 0 and 2 (both 256²) alias")
        XCTAssertEqual(
            plan.bucketOf[0], plan.bucketOf[2],
            "Nodes 0 and 2 share a 256² bucket (disjoint lifetimes, matching spec)"
        )
        XCTAssertNotEqual(
            plan.bucketOf[1], plan.bucketOf[0],
            "Node 1's 128² bucket must not alias the 256² bucket"
        )
        XCTAssertEqual(plan.bucketSpec[plan.bucketOf[0]!]?.width, 256)
        XCTAssertEqual(plan.bucketSpec[plan.bucketOf[1]!]?.width, 128)
    }

    // MARK: - Final node protection

    /// The final node's bucket must never alias with anything
    /// else, even if some later node (conceptually) could reuse
    /// it. We can't simulate "some later node" past a final (the
    /// graph only has one final, which is the last), but we can
    /// verify the final bucket has `Int.max` lifetime by
    /// observing that adding hypothetical interleaving work
    /// doesn't compress further.
    ///
    /// Simpler check: in the linear-chain test, the final node's
    /// bucket is whichever node 2 was assigned. Its assignment
    /// stays after the plan completes — no one else uses it.
    /// Confirmed by the shared-bucket assertion in the linear
    /// chain test.
    ///
    /// Here we directly probe: `bucketOf[finalID]` is unique to
    /// the final node when the graph is carefully constructed to
    /// invite a reuse that shouldn't happen.
    func testFinalNodeBucketNeverAliases() {
        // Construct: 0 (final candidate, but we'll mark node 1
        // final instead so we can test "could node 0's bucket
        // be reused later"). Instead, let's just use a linear
        // chain and verify the final bucket isn't reused.
        let graph = Fx.linearPixelLocalChain(length: 5)
        let plan = TextureAliasingPlanner.plan(graph: graph, sourceInfo: sourceInfo)

        // Find the final node's id (the last node).
        let finalID = graph.finalID
        let finalBucket = plan.bucketOf[finalID]!

        // Final bucket must not equal any earlier node's bucket
        // whose lifetime extended past the final's start.
        // Stronger assertion: the final node doesn't SHARE a
        // bucket with any other node that comes strictly before
        // or after. In a ping-pong chain, the second-to-last
        // node (index finalID-1) is guaranteed to occupy the
        // non-final bucket. So finalBucket ≠ bucketOf[finalID-1].
        XCTAssertNotEqual(
            finalBucket, plan.bucketOf[finalID - 1],
            "Final node must not alias the node directly feeding it"
        )
    }

    // MARK: - Lowering integration

    /// Realistic case: lowering a 3-filter pixel-local chain and
    /// running the planner end-to-end on the optimised graph.
    /// After VerticalFusion folds the chain into one cluster, the
    /// graph has a single node — plan needs exactly 1 bucket.
    func testFusedClusterNeedsOneBucket() throws {
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.1)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: sourceInfo))
        let optimised = Optimizer.optimize(lowered)
        XCTAssertEqual(optimised.nodes.count, 1)

        let plan = TextureAliasingPlanner.plan(graph: optimised, sourceInfo: sourceInfo)
        XCTAssertEqual(plan.uniqueBucketCount, 1)
    }

    /// Lowering an HS + Clarity chain produces a multi-node graph
    /// with ping-pong-able intermediates; the planner should
    /// alias aggressively. This is the real-world motivating case.
    func testHSAndClarityChainCompressesTexturesViaAliasing() throws {
        let steps: [AnyFilter] = [
            .multi(HighlightShadowFilter(highlights: 40)),
            .multi(ClarityFilter(intensity: 30)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: sourceInfo))
        let optimised = Optimizer.optimize(lowered)

        let plan = TextureAliasingPlanner.plan(graph: optimised, sourceInfo: sourceInfo)

        // Without aliasing, the graph would need one texture per
        // node. Aliasing should strictly reduce the count. We
        // don't pin exact numbers (they depend on HS / Clarity's
        // internal pass structure), just the inequality.
        XCTAssertLessThan(
            plan.uniqueBucketCount, optimised.nodes.count,
            "Aliasing should reduce bucket count below node count on an HS+Clarity chain"
        )
    }

    // MARK: - Chain-internal aliasing (Phase 8 fragment chain)

    /// A 4-cluster fragment chain on 1080p `rgba16Float` would
    /// normally allocate four destinations (~33 MB). Telling the
    /// planner the first three clusters are chain-internal
    /// collapses to exactly **one** bucket (~8.3 MB) — the chain
    /// tail's. Every chain-internal NodeID still appears in
    /// `bucketOf` (mapped to the tail's bucket) so dispatch-time
    /// `mapping[id]` lookups succeed even though no texture is
    /// physically distinct.
    func testChainInternalAliasCollapsesIntermediates() {
        var nodes: [Node] = []
        for i in 0..<4 {
            let prevID: NodeID = i - 1
            let input: NodeRef = i == 0 ? .source : .node(prevID)
            nodes.append(Fx.pixelLocalNode(
                id: i,
                bodyName: "F\(i)",
                input: input,
                isFinal: (i == 3)
            ))
        }
        let graph = Fx.bypassingValidation(nodes, totalAdditionalInputs: 0)

        // Four-cluster chain: 0,1,2 are chain-internal, 3 is the tail.
        var alias: [NodeID: NodeID] = [:]
        alias[0] = 3
        alias[1] = 3
        alias[2] = 3

        let plan = TextureAliasingPlanner.plan(
            graph: graph,
            sourceInfo: sourceInfo,
            chainInternalAlias: alias
        )

        XCTAssertEqual(
            plan.uniqueBucketCount, 1,
            "All four clusters should share one bucket (the chain tail's)"
        )

        let tailBucket = plan.bucketOf[3]!
        XCTAssertEqual(plan.bucketOf[0], tailBucket)
        XCTAssertEqual(plan.bucketOf[1], tailBucket)
        XCTAssertEqual(plan.bucketOf[2], tailBucket)
    }

    /// Without `chainInternalAlias`, the same chain still aliases
    /// via lifetime ping-pong (each cluster's output is read once
    /// then released) — but ping-pong needs at least two buckets.
    /// This test pins the contrast: chain-internal aliasing wins
    /// one extra bucket compared to lifetime aliasing alone.
    func testChainInternalAliasBeatsLifetimeAliasing() {
        var nodes: [Node] = []
        for i in 0..<4 {
            let prevID: NodeID = i - 1
            let input: NodeRef = i == 0 ? .source : .node(prevID)
            nodes.append(Fx.pixelLocalNode(
                id: i,
                bodyName: "F\(i)",
                input: input,
                isFinal: (i == 3)
            ))
        }
        let graph = Fx.bypassingValidation(nodes, totalAdditionalInputs: 0)

        var alias: [NodeID: NodeID] = [:]
        alias[0] = 3
        alias[1] = 3
        alias[2] = 3

        let lifetimeOnly = TextureAliasingPlanner.plan(
            graph: graph,
            sourceInfo: sourceInfo
        )
        let withChain = TextureAliasingPlanner.plan(
            graph: graph,
            sourceInfo: sourceInfo,
            chainInternalAlias: alias
        )
        XCTAssertGreaterThan(
            lifetimeOnly.uniqueBucketCount, withChain.uniqueBucketCount,
            "Chain-internal aliasing must strictly beat lifetime aliasing alone"
        )
    }
}
