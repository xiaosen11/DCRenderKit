//
//  TailSinkTests.swift
//  DCRenderKitTests
//
//  Fixture-driven tests for the Phase-2 aggressive TailSink pass.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class TailSinkTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private let pass = TailSink()

    // MARK: - Fused cluster extension

    /// A `.fusedPixelLocalCluster` producer absorbs a downstream
    /// pixelLocal by appending a new member. The downstream node is
    /// dropped; the cluster inherits its final flag when the
    /// downstream was final.
    func testClusterAbsorbsDownstreamPixelLocalAsNewMember() {
        let clusterKind: NodeKind = .fusedPixelLocalCluster(
            members: [
                FusedClusterMember(body: Fx.dummyBody("A"), uniforms: .empty, debugLabel: "A", additionalRange: 0..<0),
                FusedClusterMember(body: Fx.dummyBody("B"), uniforms: .empty, debugLabel: "B", additionalRange: 0..<0),
            ],
            wantsLinearInput: false,
            additionalNodeInputs: []
        )
        let cluster = Node(
            id: 0,
            kind: clusterKind,
            inputs: [.source],
            outputSpec: .sameAsSource,
            isFinal: false,
            debugLabel: "Cluster[A..B]"
        )
        let downstream = Fx.pixelLocalNode(id: 1, bodyName: "C", input: .node(0), isFinal: true)

        let g = PipelineGraph(nodes: [cluster, downstream], totalAdditionalInputs: 0)

        let out = pass.run(g)

        XCTAssertEqual(out.nodes.count, 1, "Cluster should have absorbed the downstream pixelLocal")
        let survivor = out.nodes[0]
        XCTAssertTrue(survivor.isFinal)
        guard case let .fusedPixelLocalCluster(members, _, _) = survivor.kind else {
            XCTFail("Expected fusedPixelLocalCluster")
            return
        }
        XCTAssertEqual(members.map { $0.body.functionName }, ["A", "B", "C"])
    }

    /// Aux inputs on the absorbed pixelLocal append to the
    /// cluster's aux union, and the new member's range covers the
    /// newly appended slots.
    func testClusterAbsorbsAuxiliariesWithRange() {
        let clusterKind: NodeKind = .fusedPixelLocalCluster(
            members: [
                FusedClusterMember(body: Fx.dummyBody("A"), uniforms: .empty, debugLabel: "A",
                                   additionalRange: 0..<1),
            ],
            wantsLinearInput: false,
            additionalNodeInputs: [.additional(0)]
        )
        let cluster = Node(
            id: 0, kind: clusterKind, inputs: [.source],
            outputSpec: .sameAsSource, isFinal: false, debugLabel: "ClusterA"
        )
        let downstream = Fx.pixelLocalNode(
            id: 1, bodyName: "B", input: .node(0),
            isFinal: true, additionalNodeInputs: [.additional(1)]
        )
        let g = PipelineGraph(nodes: [cluster, downstream], totalAdditionalInputs: 2)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 1)
        guard case let .fusedPixelLocalCluster(members, _, aux) = out.nodes[0].kind else {
            XCTFail("Expected fusedPixelLocalCluster")
            return
        }
        XCTAssertEqual(aux, [.additional(0), .additional(1)])
        XCTAssertEqual(members[0].additionalRange, 0..<1)
        XCTAssertEqual(members[1].additionalRange, 1..<2)
    }

    // MARK: - NeighborRead tail sink

    /// A `.neighborRead` producer captures the downstream
    /// pixelLocal in `tailSinkedBody`. The downstream node is
    /// dropped; the neighbour-read inherits the final flag.
    func testNeighborReadCapturesDownstreamInTailSinkedBody() {
        let neighbor = Fx.neighborReadNode(id: 0, bodyName: "Edge", radius: 1)
        let downstream = Fx.pixelLocalNode(id: 1, bodyName: "PostAdjust", input: .node(0), isFinal: true)

        let g = PipelineGraph(nodes: [neighbor, downstream], totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 1)
        let survivor = out.nodes[0]
        XCTAssertTrue(survivor.isFinal)
        XCTAssertEqual(survivor.id, 0)

        guard let sink = survivor.tailSinkedBody else {
            XCTFail("Tail-sinked body not attached")
            return
        }
        XCTAssertEqual(sink.body.functionName, "PostAdjust")
    }

    /// NeighborRead with its own aux gets extended; the tail-sinked
    /// member's range covers the appended slots.
    func testNeighborReadTailSinkAuxRangeCorrect() {
        let neighbor = Fx.neighborReadNode(
            id: 0, bodyName: "Edge", radius: 1,
            additionalNodeInputs: [.additional(0)]
        )
        let downstream = Fx.pixelLocalNode(
            id: 1, bodyName: "PostAdjust", input: .node(0),
            isFinal: true,
            additionalNodeInputs: [.additional(1), .additional(2)]
        )
        let g = PipelineGraph(nodes: [neighbor, downstream], totalAdditionalInputs: 3)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 1)
        guard case let .neighborRead(_, _, _, aux) = out.nodes[0].kind else {
            XCTFail("Expected neighborRead")
            return
        }
        XCTAssertEqual(aux, [.additional(0), .additional(1), .additional(2)])

        XCTAssertEqual(out.nodes[0].tailSinkedBody?.additionalRange, 1..<3)
    }

    // MARK: - No-fold conditions

    /// Fan-out: producer has multiple consumers → no sink.
    func testFanOutPreventsTailSink() {
        let neighbor = Fx.neighborReadNode(id: 0, bodyName: "Edge", radius: 1)
        let consumerA = Fx.pixelLocalNode(id: 1, bodyName: "A", input: .node(0))
        let consumerB = Fx.pixelLocalNode(
            id: 2, bodyName: "B", input: .node(0),
            isFinal: true, additionalNodeInputs: [.node(1)]
        )
        let g = PipelineGraph(
            nodes: [neighbor, consumerA, consumerB],
            totalAdditionalInputs: 0
        )

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
        for node in out.nodes {
            XCTAssertNil(node.tailSinkedBody)
        }
    }

    /// Regression — TailSink must NOT absorb a non-final pixelLocal
    /// that still has downstream consumers. This pattern occurs when
    /// a multi-pass filter's later pass references an earlier
    /// pixelLocal-style node by `NodeRef.node(P.id)`. Dropping P would
    /// orphan that reference, and `PipelineGraph.init`'s validator
    /// then aborts with "node X references Y which is not declared
    /// earlier".
    ///
    /// Original repro: a real-world chain ending with
    /// HighlightShadow + ClarityFilter (multi-pass) — Clarity's pass
    /// #7 (downsample) referenced an earlier pixelLocal that
    /// TailSink had absorbed. The crash was deterministic.
    func testNonFinalPixelLocalWithDownstreamConsumerIsNotAbsorbed() {
        // Producer M: a fused cluster the optimiser is happy to
        // extend if its only consumer is the next pixelLocal P.
        let cluster = Node(
            id: 0,
            kind: .fusedPixelLocalCluster(
                members: [
                    FusedClusterMember(
                        body: Fx.dummyBody("Exposure"),
                        uniforms: .empty,
                        debugLabel: "Exposure",
                        additionalRange: 0..<0
                    ),
                ],
                wantsLinearInput: false,
                additionalNodeInputs: []
            ),
            inputs: [.source],
            outputSpec: .sameAsSource,
            isFinal: false,
            debugLabel: "ClusterExposure"
        )

        // P: pixelLocal with M as its only input. Crucially, P is
        // *not* final and is read by another node downstream.
        let p = Fx.pixelLocalNode(
            id: 1,
            bodyName: "PreClarity",
            input: .node(0),
            isFinal: false
        )

        // The downstream consumer that still needs P's id intact.
        // Modeled as a `.downsample` (the same kind that triggered
        // the original ClarityFilter#7 crash) which `dependencyRefs`
        // counts via `inputs`.
        let downstream = Node(
            id: 2,
            kind: .downsample(factor: 4, kind: .guidedLuma),
            inputs: [.node(1)],
            outputSpec: .scaled(factor: 0.25),
            isFinal: true,
            debugLabel: "ClarityFilter#0.downsample"
        )

        let graph = PipelineGraph(
            nodes: [cluster, p, downstream],
            totalAdditionalInputs: 0
        )

        // `pass.run` re-builds the result through the validating
        // PipelineGraph initialiser, so the original bug surfaced as
        // a fatalError inside this call. The fix turns the run into a
        // no-op for this graph shape.
        let out = pass.run(graph)

        // All three nodes must survive — TailSink is forbidden from
        // absorbing P because doing so would orphan node 2's
        // reference to node 1.
        XCTAssertEqual(out.nodes.count, 3, "TailSink must not drop P when P has downstream consumers")
        XCTAssertEqual(Set(out.nodes.map { $0.id }), [0, 1, 2])
    }

    /// NativeCompute producer is opaque → no sink.
    func testNativeComputeProducerIsNotAbsorbed() {
        let nc = Fx.nativeComputeNode(id: 0, kernelName: "Opaque")
        let downstream = Fx.pixelLocalNode(id: 1, bodyName: "Post", input: .node(0), isFinal: true)
        let g = PipelineGraph(nodes: [nc, downstream], totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2, "NativeCompute cannot splice tail body")
        XCTAssertNil(out.nodes[0].tailSinkedBody)
    }

    /// Downstream pixelLocal that already carries an inlined head
    /// body should not be tail-sunk (mixing head + tail inlining
    /// is out of scope).
    func testDownstreamWithInlinedHeadBodyIsNotSunk() {
        let neighbor = Fx.neighborReadNode(id: 0, bodyName: "Edge", radius: 1)
        let downstreamWithHeadInline = Node(
            id: 1,
            kind: .pixelLocal(
                body: Fx.dummyBody("Post"),
                uniforms: .empty,
                wantsLinearInput: false,
                additionalNodeInputs: []
            ),
            inputs: [.node(0)],
            outputSpec: .sameAsSource,
            isFinal: true,
            debugLabel: "Post",
            inlinedBodyBeforeSample: FusedClusterMember(
                body: Fx.dummyBody("Pre"),
                uniforms: .empty,
                debugLabel: "Pre",
                additionalRange: 0..<0
            )
        )
        let g = PipelineGraph(nodes: [neighbor, downstreamWithHeadInline], totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2, "Head-inlined downstream must not tail-sink")
    }

    /// Producer with `outputSpec != .sameAsSource` isn't a sink
    /// target (resolution boundary).
    func testScaledProducerIsNotASinkTarget() {
        let scaled = Node(
            id: 0,
            kind: .neighborRead(
                body: Fx.dummyBody("Edge", kind: .neighborRead(radius: 1)),
                uniforms: .empty,
                radiusHint: 1,
                additionalNodeInputs: []
            ),
            inputs: [.source],
            outputSpec: .scaled(factor: 0.5),
            isFinal: false,
            debugLabel: "Scaled"
        )
        let downstream = Fx.pixelLocalNode(id: 1, bodyName: "Post", input: .node(0), isFinal: true)
        let g = PipelineGraph(nodes: [scaled, downstream], totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2)
    }

    // MARK: - No-op

    /// Pipeline without a tail-sink opportunity (pixelLocal-only)
    /// is a no-op for TailSink (VerticalFusion would have handled
    /// it earlier in the real pipeline).
    func testLinearPixelLocalNoOp() {
        let g = Fx.linearPixelLocalChain(length: 3)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, g.nodes.map { $0.id })
    }

    /// Graph without any downstream pixelLocal.
    func testNeighborReadOnlyNoOp() {
        let nodes: [Node] = [
            Fx.neighborReadNode(id: 0, bodyName: "E1", radius: 1),
            Fx.neighborReadNode(id: 1, bodyName: "E2", radius: 1, input: .node(0), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2)
        for node in out.nodes { XCTAssertNil(node.tailSinkedBody) }
    }

    // MARK: - Pass name

    func testPassNameIsStable() {
        XCTAssertEqual(pass.name, "TailSink")
    }
}
