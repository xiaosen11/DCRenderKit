//
//  VerticalFusionTests.swift
//  DCRenderKitTests
//
//  Fixture-driven tests for the Phase-2 VerticalFusion pass. Each
//  test constructs a hand-built `PipelineGraph` with specific
//  merge / no-merge expectations, runs the pass, and asserts the
//  shape of the output.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class VerticalFusionTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private let pass = VerticalFusion()

    // MARK: - Merge behaviour

    /// Three adjacent pixel-local nodes form a single cluster with
    /// three members, inputs inherited from the head, and the
    /// final flag preserved on the cluster.
    func testThreeAdjacentPixelLocalsMergeIntoOneCluster() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "A"),
            Fx.pixelLocalNode(id: 1, bodyName: "B", input: .node(0)),
            Fx.pixelLocalNode(id: 2, bodyName: "C", input: .node(1), isFinal: true),
        ]
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let output = pass.run(input)

        XCTAssertEqual(output.nodes.count, 1, "Three pixelLocals collapse to one cluster node")
        guard case let .fusedPixelLocalCluster(members, linear, aux) = output.nodes[0].kind else {
            XCTFail("Expected fusedPixelLocalCluster, got \(output.nodes[0].kind)")
            return
        }
        XCTAssertEqual(members.map { $0.body.functionName }, ["A", "B", "C"])
        XCTAssertFalse(linear)
        XCTAssertTrue(aux.isEmpty)
        XCTAssertEqual(output.nodes[0].inputs, [.source])
        XCTAssertTrue(output.nodes[0].isFinal)
        XCTAssertEqual(output.finalID, output.nodes[0].id)
    }

    /// Two pixel-locals with auxiliary inputs merge into a cluster
    /// whose `additionalNodeInputs` is the union of both members'
    /// auxiliaries, and each member's `additionalRange` covers its
    /// original slice.
    func testAuxiliaryInputsMergeWithCorrectRanges() {
        let nodes: [Node] = [
            // Producer node (not part of cluster) emitting an aux
            // texture used by the second cluster member.
            Fx.pixelLocalNode(id: 10, bodyName: "AuxSrc"),
            Fx.pixelLocalNode(
                id: 0,
                bodyName: "Head",
                additionalNodeInputs: [.additional(0)]
            ),
            Fx.pixelLocalNode(
                id: 1,
                bodyName: "Tail",
                input: .node(0),
                isFinal: true,
                wantsLinearInput: false,
                additionalNodeInputs: [.node(10), .additional(1)]
            ),
        ]
        // Graph-legal ordering: 10 is produced first but not
        // consumed by anyone in a way that turns it into an
        // unreachable ghost; mark it dead to sidestep the scenario.
        // To keep the fixture simple, attach it as the aux input of
        // Tail so it stays alive.
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 2)

        let output = pass.run(input)

        // Expect: AuxSrc stays, the two pixelLocals merge.
        XCTAssertEqual(output.nodes.count, 2)
        guard case let .fusedPixelLocalCluster(members, _, aux) =
                output.nodes.first(where: {
                    if case .fusedPixelLocalCluster = $0.kind { return true } else { return false }
                })!.kind
        else {
            XCTFail("Expected a fusedPixelLocalCluster")
            return
        }
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(members[0].body.functionName, "Head")
        XCTAssertEqual(members[1].body.functionName, "Tail")

        // Union order: Head's [.additional(0)] then Tail's
        // [.node(10), .additional(1)]. AuxSrc's id is remapped to
        // whichever id survived — in this fixture it stays 10
        // because no cluster absorbed it.
        XCTAssertEqual(aux, [.additional(0), .node(10), .additional(1)])

        // Ranges: Head uses [0..<1), Tail uses [1..<3).
        XCTAssertEqual(members[0].additionalRange, 0..<1)
        XCTAssertEqual(members[1].additionalRange, 1..<3)
    }

    // MARK: - Fan-out guard

    /// If `prev`'s output is read by two consumers, merging into
    /// one of them would orphan the other. The pass must leave
    /// `prev` as its own node.
    func testFanOutPreventsMerge() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Shared"),
            Fx.pixelLocalNode(id: 1, bodyName: "ConsumerA", input: .node(0)),
            Fx.pixelLocalNode(
                id: 2,
                bodyName: "ConsumerB",
                input: .node(0),
                isFinal: true,
                additionalNodeInputs: [.node(1)]
            ),
        ]
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let output = pass.run(input)

        // No fusion: 0 has two consumers (1 and 2), so neither
        // edge is mergeable.
        XCTAssertEqual(output.nodes.count, 3)
        for node in output.nodes {
            if case .fusedPixelLocalCluster = node.kind {
                XCTFail("Fan-out should have prevented fusion")
            }
        }
    }

    /// A pixelLocal node that itself is `isFinal` cannot be merged
    /// into a later node (it has no later node), and an upstream
    /// pixelLocal cannot be merged with it if the upstream has
    /// another consumer — but being final alone doesn't prevent
    /// merging with the node before it.
    ///
    /// Here the middle node is final; the pass should merge the
    /// two nodes into one cluster, and the cluster inherits the
    /// final flag.
    func testFinalFlagMergesIntoCluster() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "A"),
            Fx.pixelLocalNode(id: 1, bodyName: "B", input: .node(0), isFinal: true),
        ]
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let output = pass.run(input)

        XCTAssertEqual(output.nodes.count, 1)
        XCTAssertTrue(output.nodes[0].isFinal)
    }

    // MARK: - Colour-space mismatch

    /// Two pixelLocals with opposite `wantsLinearInput` must not
    /// merge; the compiler would need a gamma wrapper between them
    /// that the uber kernel can't currently emit. The pass leaves
    /// them as separate nodes.
    func testDifferentWantsLinearDoesNotMerge() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Gamma", wantsLinearInput: false),
            Fx.pixelLocalNode(
                id: 1,
                bodyName: "Linear",
                input: .node(0),
                isFinal: true,
                wantsLinearInput: true
            ),
        ]
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let output = pass.run(input)

        XCTAssertEqual(output.nodes.count, 2)
        for node in output.nodes {
            if case .fusedPixelLocalCluster = node.kind {
                XCTFail("Different wantsLinear flags must not merge")
            }
        }
    }

    // MARK: - Resolution-changing node interrupts

    /// A `.scaled(factor:)` output in the middle stops the cluster.
    /// Here the head has the scaled output, so it isn't eligible
    /// to start a cluster in the first place; the tail starts its
    /// own cluster of length 1 (also no merge with nothing after).
    func testResolutionChangeInterruptsCluster() {
        let nodes: [Node] = [
            // Head has outputSpec != .sameAsSource → not cluster-eligible.
            Node(
                id: 0,
                kind: .pixelLocal(
                    body: Fx.dummyBody("Scaled"),
                    uniforms: .empty,
                    wantsLinearInput: false,
                    additionalNodeInputs: []
                ),
                inputs: [.source],
                outputSpec: .scaled(factor: 0.5),
                isFinal: false,
                debugLabel: "Scaled"
            ),
            Fx.pixelLocalNode(id: 1, bodyName: "Tail", input: .node(0), isFinal: true),
        ]
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let output = pass.run(input)

        XCTAssertEqual(output.nodes.count, 2)
        for node in output.nodes {
            if case .fusedPixelLocalCluster = node.kind {
                XCTFail("Resolution-change nodes must not participate in vertical fusion")
            }
        }
    }

    // MARK: - Non-pixelLocal interrupts

    /// A mixed chain A(pl) → B(pl) → C(neighborRead) → D(pl) → E(pl)
    /// produces cluster[A,B] + C + cluster[D,E]. The neighborRead
    /// breaks the first cluster and the second cluster restarts
    /// from D.
    func testNeighborReadInterruptsCluster() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "A"),
            Fx.pixelLocalNode(id: 1, bodyName: "B", input: .node(0)),
            Fx.neighborReadNode(id: 2, bodyName: "C", radius: 1, input: .node(1)),
            Fx.pixelLocalNode(id: 3, bodyName: "D", input: .node(2)),
            Fx.pixelLocalNode(id: 4, bodyName: "E", input: .node(3), isFinal: true),
        ]
        let input = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let output = pass.run(input)

        // Expect 3 nodes: [cluster of A,B], C (neighborRead), [cluster of D,E]
        XCTAssertEqual(output.nodes.count, 3)
        guard
            case .fusedPixelLocalCluster(let m0, _, _) = output.nodes[0].kind,
            case .neighborRead = output.nodes[1].kind,
            case .fusedPixelLocalCluster(let m2, _, _) = output.nodes[2].kind
        else {
            XCTFail("Expected [cluster, neighborRead, cluster], got\n\(output.dump)")
            return
        }
        XCTAssertEqual(m0.map { $0.body.functionName }, ["A", "B"])
        XCTAssertEqual(m2.map { $0.body.functionName }, ["D", "E"])
        XCTAssertTrue(output.nodes[2].isFinal)
    }

    // MARK: - No-op

    /// A single pixelLocal graph: nothing to merge. Pass returns
    /// the graph verbatim.
    func testSinglePixelLocalNoOp() {
        let g = Fx.linearPixelLocalChain(length: 1)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, g.nodes.map { $0.id })
    }

    /// A chain that doesn't satisfy any merge condition (e.g. all
    /// nodes are neighborRead) passes through unchanged.
    func testNonPixelLocalChainNoOp() {
        let nodes: [Node] = [
            Fx.neighborReadNode(id: 0, bodyName: "A", radius: 1),
            Fx.neighborReadNode(id: 1, bodyName: "B", radius: 1, input: .node(0)),
            Fx.neighborReadNode(id: 2, bodyName: "C", radius: 1, input: .node(1), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
        for node in out.nodes {
            if case .fusedPixelLocalCluster = node.kind {
                XCTFail("neighborRead-only chain must not fuse")
            }
        }
    }

    // MARK: - Pass name

    func testPassNameIsStable() {
        XCTAssertEqual(pass.name, "VerticalFusion")
    }
}
