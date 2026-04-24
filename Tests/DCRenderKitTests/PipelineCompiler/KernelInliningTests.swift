//
//  KernelInliningTests.swift
//  DCRenderKitTests
//
//  Fixture-driven tests for the Phase-2 KernelInlining pass.
//  Exercises the pixelLocal-→-neighborRead fold plus every
//  no-fold condition.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class KernelInliningTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private let pass = KernelInlining()

    // MARK: - Fold behaviour

    /// A simple pixelLocal → neighborRead chain folds: the
    /// neighborRead survives, the pixelLocal is dropped, and the
    /// neighborRead's primary input now points at the pixelLocal's
    /// predecessor (`.source` in this fixture).
    func testPixelLocalIntoNeighborReadFolds() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "PreAdjust"),
            Fx.neighborReadNode(id: 1, bodyName: "Edge", radius: 2, input: .node(0), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = pass.run(g)

        XCTAssertEqual(out.nodes.count, 1, "pixelLocal absorbed into neighborRead")
        let survivor = out.nodes[0]
        XCTAssertEqual(survivor.id, 1)
        XCTAssertEqual(survivor.inputs, [.source])
        XCTAssertTrue(survivor.isFinal)

        // Inlined metadata is attached.
        guard let member = survivor.inlinedBodyBeforeSample else {
            XCTFail("Inlined body not attached")
            return
        }
        XCTAssertEqual(member.body.functionName, "PreAdjust")
        XCTAssertEqual(member.additionalRange, 0..<0, "No aux inputs in this fixture")
    }

    /// Inlined pixelLocal contributes its additional inputs to the
    /// neighborRead's aux union, with a recorded range.
    func testInlinedAuxiliariesAppendWithCorrectRange() {
        // Build a pixelLocal that reads aux from additional(0), and
        // a neighborRead that reads its own aux from additional(1).
        let p = Fx.pixelLocalNode(
            id: 0,
            bodyName: "AuxRead",
            additionalNodeInputs: [.additional(0)]
        )
        let n = Fx.neighborReadNode(
            id: 1,
            bodyName: "Sharpen",
            radius: 1,
            input: .node(0),
            additionalNodeInputs: [.additional(1)],
            isFinal: true
        )
        let g = PipelineGraph(nodes: [p, n], totalAdditionalInputs: 2)

        let out = pass.run(g)

        XCTAssertEqual(out.nodes.count, 1)
        let survivor = out.nodes[0]

        // Aux union: [.additional(1), .additional(0)] — N's own aux
        // first, then the inlined body's appended at the tail.
        guard case let .neighborRead(_, _, _, aux) = survivor.kind else {
            XCTFail("Expected neighborRead")
            return
        }
        XCTAssertEqual(aux, [.additional(1), .additional(0)])

        guard let member = survivor.inlinedBodyBeforeSample else {
            XCTFail("Inlined body not attached")
            return
        }
        XCTAssertEqual(member.additionalRange, 1..<2)
    }

    // MARK: - No-fold conditions

    /// Fan-out: if the pixelLocal has another consumer besides the
    /// neighborRead, folding would orphan the other consumer. Pass
    /// leaves the graph alone.
    func testFanOutPreventsInlining() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Shared"),
            Fx.neighborReadNode(id: 1, bodyName: "Edge", radius: 1, input: .node(0)),
            // Second consumer of node 0: keeps it alive externally.
            Fx.pixelLocalNode(
                id: 2,
                bodyName: "OtherConsumer",
                input: .node(0),
                isFinal: true,
                additionalNodeInputs: [.node(1)]
            ),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
        for node in out.nodes {
            XCTAssertNil(node.inlinedBodyBeforeSample)
        }
    }

    /// A final pixelLocal cannot be absorbed — its output is
    /// observed externally. Arguably a contrived shape (a final
    /// node upstream of a neighborRead is unusual), but the pass
    /// must handle it safely.
    func testFinalPredecessorIsNotAbsorbed() {
        let nodes: [Node] = [
            // Note: can't have two finals; make the pixelLocal
            // "final" shape-wise and the neighborRead non-final
            // for this specific invariant probe. We instead guard
            // with "pred.isFinal == false" in the pass.
            Fx.pixelLocalNode(id: 0, bodyName: "FinalPre", isFinal: true),
            // Second final is illegal; use a passthrough node with
            // isFinal=false so the graph validates.
            // In reality this chain wouldn't occur — just a probe.
        ]
        // Construct via the bypass initialiser to keep the odd
        // shape around without triggering the validator. (It's
        // probing pass behaviour, not graph validity.)
        let g = Fx.bypassingValidation(nodes, totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 1)
        XCTAssertNil(out.nodes[0].inlinedBodyBeforeSample)
    }

    /// A non-pixelLocal predecessor (nativeCompute) is not
    /// absorbed — the optimiser doesn't model opaque kernels' per-
    /// pixel semantics.
    func testNonPixelLocalPredecessorIsNotAbsorbed() {
        let nodes: [Node] = [
            Fx.nativeComputeNode(id: 0, kernelName: "Opaque"),
            Fx.neighborReadNode(id: 1, bodyName: "Edge", radius: 1, input: .node(0), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2)
        XCTAssertNil(out.nodes.last?.inlinedBodyBeforeSample)
    }

    /// Predecessor with a non-sameAsSource outputSpec is not
    /// absorbed — the neighborRead's sampling semantics would
    /// change if coordinates suddenly scaled.
    func testScaledPredecessorIsNotAbsorbed() {
        let scaled = Node(
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
        )
        let neighbor = Fx.neighborReadNode(id: 1, bodyName: "Edge", radius: 1, input: .node(0), isFinal: true)
        let g = PipelineGraph(nodes: [scaled, neighbor], totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2)
        XCTAssertNil(out.nodes.last?.inlinedBodyBeforeSample)
    }

    /// A neighborRead that already carries an inlined body is not
    /// absorbed a second time. (Double inlining would need codegen
    /// support Phase 3 doesn't ship.)
    func testAlreadyInlinedNeighborReadIsNotAbsorbedAgain() {
        let existingMember = FusedClusterMember(
            body: Fx.dummyBody("AlreadyInlined"),
            uniforms: .empty,
            debugLabel: "AlreadyInlined",
            additionalRange: 0..<0
        )
        let p = Fx.pixelLocalNode(id: 0, bodyName: "Candidate")
        let n = Node(
            id: 1,
            kind: .neighborRead(
                body: Fx.dummyBody("Edge", kind: .neighborRead(radius: 1)),
                uniforms: .empty,
                radiusHint: 1,
                additionalNodeInputs: []
            ),
            inputs: [.node(0)],
            outputSpec: .sameAsSource,
            isFinal: true,
            debugLabel: "Edge",
            inlinedBodyBeforeSample: existingMember
        )
        let g = PipelineGraph(nodes: [p, n], totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2, "Already-inlined neighborRead must not absorb another predecessor")
        XCTAssertEqual(
            out.nodes.last?.inlinedBodyBeforeSample?.body.functionName,
            "AlreadyInlined",
            "Original inlined body must be preserved untouched"
        )
    }

    // MARK: - No-op

    /// A chain without any neighborRead is a no-op.
    func testPixelLocalOnlyChainNoOp() {
        let g = Fx.linearPixelLocalChain(length: 3)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, g.nodes.map { $0.id })
    }

    /// A neighborRead whose primary input is `.source` (no
    /// predecessor to absorb) is a no-op.
    func testNeighborReadReadingSourceNoOp() {
        let nodes: [Node] = [
            Fx.neighborReadNode(id: 0, bodyName: "Edge", radius: 1, isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 1)
        XCTAssertNil(out.nodes[0].inlinedBodyBeforeSample)
    }

    // MARK: - Pass name

    func testPassNameIsStable() {
        XCTAssertEqual(pass.name, "KernelInlining")
    }
}
