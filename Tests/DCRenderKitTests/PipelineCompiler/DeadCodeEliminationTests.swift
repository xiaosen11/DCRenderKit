//
//  DeadCodeEliminationTests.swift
//  DCRenderKitTests
//
//  Fixture-driven tests for the Phase-2 DCE pass. Every test feeds
//  a hand-built `PipelineGraph` to `DeadCodeElimination().run(_:)`
//  and asserts the expected node-survival shape.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class DeadCodeEliminationTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private let dce = DeadCodeElimination()

    // MARK: - Baseline: no dead nodes ⇒ graph unchanged

    /// A linear chain has every node reachable from the final, so
    /// DCE returns the graph verbatim. Comparing node IDs by-value
    /// is sufficient — node equality isn't needed here.
    func testLinearChainIsUnchanged() {
        let g = Fx.linearPixelLocalChain(length: 4)
        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, g.nodes.map { $0.id })
        XCTAssertEqual(out.finalID, g.finalID)
        XCTAssertEqual(out.totalAdditionalInputs, g.totalAdditionalInputs)
    }

    /// A single-node graph is trivially reachable (the sole node is
    /// final).
    func testSingleNodeIsUnchanged() {
        let g = Fx.linearPixelLocalChain(length: 1)
        let out = dce.run(g)
        XCTAssertEqual(out.nodes.count, 1)
    }

    // MARK: - Single dead node

    /// A node that produces its output but is never consumed by any
    /// other node and is not the final node is pure dead. Derivation:
    /// DCE's reachability seed is `finalID` only; nodes whose IDs
    /// never appear in any survivor's `dependencyRefs` never land
    /// in the reachable set.
    func testSingleDeadNodeRemoved() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "A"),                     // live: source
            Fx.pixelLocalNode(id: 1, bodyName: "B", input: .node(0)),    // live: feeds final
            Fx.pixelLocalNode(id: 2, bodyName: "OrphanC", input: .node(0)),  // DEAD
            Fx.pixelLocalNode(id: 3, bodyName: "Final", input: .node(1), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, [0, 1, 3])
        XCTAssertEqual(out.finalID, 3)
        XCTAssertEqual(out.totalAdditionalInputs, 0)
    }

    // MARK: - Chained dead nodes

    /// Dead → Dead chain: two nodes neither referenced by the final
    /// nor by anything reachable. Both must be removed, and the
    /// reachable set must stop expanding when it can't discover new
    /// live nodes.
    func testChainedDeadNodesBothRemoved() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "A"),
            Fx.pixelLocalNode(id: 1, bodyName: "DeadB", input: .node(0)),    // dead
            Fx.pixelLocalNode(id: 2, bodyName: "DeadC", input: .node(1)),    // dead (reaches via dead B)
            Fx.pixelLocalNode(id: 3, bodyName: "Final", input: .node(0), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, [0, 3])
    }

    // MARK: - Reachability via dependency refs, not just inputs

    /// `.pixelLocal`'s `additionalNodeInputs` (LUT3D style auxiliary
    /// texture produced by an earlier node) must count as a
    /// reachability edge, not just the primary `inputs`.
    ///
    /// Setup: node 1 is a `pixelLocal` whose **only** dependency on
    /// node 0 comes through `additionalNodeInputs`; node 1 is the
    /// final. DCE must keep node 0 alive.
    func testAdditionalInputsContributeToReachability() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "AuxProducer"),
            Fx.pixelLocalNode(
                id: 1,
                bodyName: "Final",
                input: .source,
                isFinal: true,
                additionalNodeInputs: [.node(0)]
            ),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, [0, 1])
    }

    /// `.nativeCompute`'s `additionalNodeInputs` likewise contribute.
    func testNativeComputeAdditionalInputsContributeToReachability() {
        let nodes: [Node] = [
            Fx.nativeComputeNode(id: 0, kernelName: "DCRGuidedDownsampleLuma"),
            Fx.nativeComputeNode(
                id: 1,
                kernelName: "DCRHighlightShadowApply",
                input: .source,
                additionalNodeInputs: [.node(0)],
                isFinal: true
            ),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, [0, 1])
    }

    // MARK: - .source and .additional don't gate reachability

    /// `.source` and `.additional(_)` aren't nodes, so they can't
    /// keep a node alive by themselves. In this fixture, node 0
    /// reads `.source` and `.additional(0)` only — it has no
    /// consumer — and must be removed. Node 1 is the final node and
    /// reads `.source`, not node 0.
    func testNonNodeRefsDoNotKeepProducersAlive() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(
                id: 0,
                bodyName: "OrphanAuxConsumer",
                input: .source,
                additionalNodeInputs: [.additional(0)]
            ),
            Fx.pixelLocalNode(id: 1, bodyName: "Final", input: .source, isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 1)

        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, [1])
        XCTAssertEqual(out.totalAdditionalInputs, 1, "DCE preserves totalAdditionalInputs even if the consumer dies")
    }

    // MARK: - The final node itself

    /// Even if the "graph" is just one node with no input nodes at
    /// all (just `.source`), DCE keeps it. Reachability seed is
    /// `finalID`, which is always the surviving node.
    func testFinalNodeIsAlwaysKept() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Lone", isFinal: true)
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertEqual(dce.run(g).nodes.map { $0.id }, [0])
    }

    // MARK: - DCE is a no-op if nothing to remove

    /// Confirm the "return the input unchanged" shortcut is taken
    /// when no node is dead — this is an observable optimisation
    /// (identity `===` behaviour on `.nodes` isn't checkable on
    /// value types, but equality of the `id` sequence is).
    func testNoOpWhenNothingToRemove() {
        let g = Fx.linearPixelLocalChain(length: 3)
        let out = dce.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, g.nodes.map { $0.id })
        XCTAssertEqual(out.finalID, g.finalID)
    }

    // MARK: - Pass name

    /// Pass name is stable and non-empty so debug logs can quote it.
    func testPassNameIsStable() {
        XCTAssertEqual(dce.name, "DCE")
    }
}
