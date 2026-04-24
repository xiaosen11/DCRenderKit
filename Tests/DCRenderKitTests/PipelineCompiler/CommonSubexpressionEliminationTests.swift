//
//  CommonSubexpressionEliminationTests.swift
//  DCRenderKitTests
//
//  Fixture-driven tests for the Phase-2 CSE pass. Each test sets
//  up a graph that exercises one fold / no-fold condition and
//  asserts the expected survivor shape.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class CommonSubexpressionEliminationTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private let pass = CommonSubexpressionElimination()

    // MARK: - Fold behaviour

    /// Two `nativeCompute` nodes with identical kernel name,
    /// uniform bytes, inputs, and outputSpec fold into one. Models
    /// the HS + Clarity guided-filter downsample sharing.
    func testTwoIdenticalNativeComputeNodesFoldIntoOne() {
        let nodes: [Node] = [
            Fx.nativeComputeNode(id: 0, kernelName: "DCRGuidedDownsampleLuma"),
            Fx.nativeComputeNode(id: 1, kernelName: "DCRGuidedDownsampleLuma"),
            // Two later nodes each consume one downsample. After
            // CSE, both must point to the surviving downsample id.
            Fx.pixelLocalNode(id: 2, bodyName: "HSApply", input: .node(0)),
            Fx.pixelLocalNode(id: 3, bodyName: "ClarityApply", input: .node(1), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = pass.run(g)

        XCTAssertEqual(out.nodes.count, 3, "Duplicate downsample collapses to one")
        // Both HSApply (id 2) and ClarityApply (id 3) must now
        // reference the same downsample id (node 0 was seen first).
        guard let hs = out.nodes.first(where: { $0.id == 2 }),
              let cl = out.nodes.first(where: { $0.id == 3 }) else {
            XCTFail("Consumer nodes missing after CSE")
            return
        }
        XCTAssertEqual(hs.inputs, [.node(0)])
        XCTAssertEqual(cl.inputs, [.node(0)])
    }

    /// Two pixelLocal nodes with identical body and uniforms
    /// (zero-byte uniforms in the fixture helpers) fold.
    func testTwoIdenticalPixelLocalNodesFold() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Shared"),
            Fx.pixelLocalNode(id: 1, bodyName: "Shared"),
            Fx.pixelLocalNode(id: 2, bodyName: "ConsumerA", input: .node(0)),
            Fx.pixelLocalNode(id: 3, bodyName: "ConsumerB", input: .node(1), isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)

        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
        XCTAssertEqual(out.nodes.first { $0.id == 3 }?.inputs, [.node(0)])
    }

    // MARK: - No-fold conditions

    /// Different kernel names don't fold.
    func testDifferentKernelNamesDoNotFold() {
        let nodes: [Node] = [
            Fx.nativeComputeNode(id: 0, kernelName: "KernelA"),
            Fx.nativeComputeNode(id: 1, kernelName: "KernelB"),
            Fx.pixelLocalNode(id: 2, bodyName: "F", input: .node(0),
                              isFinal: true,
                              additionalNodeInputs: [.node(1)]),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
    }

    /// Different inputs don't fold (even with identical kernel).
    func testDifferentInputsDoNotFold() {
        let nodes: [Node] = [
            Fx.pixelLocalNode(id: 0, bodyName: "Src1"),
            Fx.pixelLocalNode(id: 1, bodyName: "Src2"),
            Fx.nativeComputeNode(id: 2, kernelName: "KernelA", input: .node(0)),
            Fx.nativeComputeNode(id: 3, kernelName: "KernelA", input: .node(1)),
            Fx.pixelLocalNode(id: 4, bodyName: "Final", input: .node(2),
                              isFinal: true,
                              additionalNodeInputs: [.node(3)]),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 5, "Same kernel with different inputs must not fold")
    }

    /// Different outputSpec doesn't fold.
    func testDifferentOutputSpecDoesNotFold() {
        let nodes: [Node] = [
            Fx.nativeComputeNode(
                id: 0,
                kernelName: "KernelX",
                outputSpec: .scaled(factor: 0.5)
            ),
            Fx.nativeComputeNode(
                id: 1,
                kernelName: "KernelX",
                outputSpec: .sameAsSource
            ),
            Fx.pixelLocalNode(id: 2, bodyName: "F", input: .node(1),
                              isFinal: true,
                              additionalNodeInputs: [.node(0)]),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
    }

    /// `.fusedPixelLocalCluster` never participates in CSE
    /// (signature returns nil).
    func testFusedClustersDoNotFold() {
        // Build two identical clusters by hand — this is ugly but
        // it's the only way to create a fusedPixelLocalCluster
        // without going through VerticalFusion.
        let clusterKind: NodeKind = .fusedPixelLocalCluster(
            members: [
                FusedClusterMember(
                    body: Fx.dummyBody("A"),
                    uniforms: .empty,
                    debugLabel: "A",
                    additionalRange: 0..<0
                )
            ],
            wantsLinearInput: false,
            additionalNodeInputs: []
        )
        let cluster0 = Node(
            id: 0, kind: clusterKind, inputs: [.source],
            outputSpec: .sameAsSource, isFinal: false,
            debugLabel: "Cluster0"
        )
        let cluster1 = Node(
            id: 1, kind: clusterKind, inputs: [.source],
            outputSpec: .sameAsSource, isFinal: false,
            debugLabel: "Cluster1"
        )
        let finalNode = Fx.pixelLocalNode(
            id: 2,
            bodyName: "F",
            input: .node(0),
            isFinal: true,
            additionalNodeInputs: [.node(1)]
        )

        let g = PipelineGraph(
            nodes: [cluster0, cluster1, finalNode],
            totalAdditionalInputs: 0
        )

        let out = pass.run(g)
        XCTAssertEqual(
            out.nodes.count, 3,
            "Fused clusters should not participate in CSE even when identical"
        )
    }

    /// Final-flagged nodes do not fold even if signature matches.
    func testFinalNodeDoesNotFoldIntoEarlierDuplicate() {
        let nodes: [Node] = [
            Fx.nativeComputeNode(id: 0, kernelName: "SharedKernel"),
            Fx.nativeComputeNode(id: 1, kernelName: "SharedKernel", isFinal: true),
        ]
        let g = PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
        let out = pass.run(g)
        // The final node stays. Node 0 is dead after CSE would have
        // folded it, but CSE itself doesn't run DCE — DCE runs
        // separately. So both nodes remain; DCE (earlier in the
        // sequence) would have removed node 0 had it been unused
        // before CSE. In this fixture, node 0 has no consumers
        // anyway, so in the full Optimizer.optimize sequence DCE
        // runs first and drops node 0 pre-CSE. We assert only that
        // CSE itself does not touch the final node's shape.
        XCTAssertTrue(out.nodes.contains(where: { $0.id == 1 && $0.isFinal }))
    }

    // MARK: - No-op

    /// Graph with no duplicates passes through unchanged.
    func testLinearChainNoOp() {
        let g = Fx.linearPixelLocalChain(length: 4)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.map { $0.id }, g.nodes.map { $0.id })
    }

    /// Signature depends on uniform bytes: two nodes with
    /// different uniform payloads must not fold. Use `nativeCompute`
    /// with small uniform structs to exercise the byte comparison.
    func testDifferentUniformBytesDoNotFold() {
        struct TestU { var value: Float }
        let u0 = FilterUniforms(TestU(value: 1.0))
        let u1 = FilterUniforms(TestU(value: 2.0))

        let n0 = Node(
            id: 0,
            kind: .nativeCompute(
                kernelName: "K",
                uniforms: u0,
                additionalNodeInputs: []
            ),
            inputs: [.source],
            outputSpec: .sameAsSource,
            isFinal: false,
            debugLabel: "n0"
        )
        let n1 = Node(
            id: 1,
            kind: .nativeCompute(
                kernelName: "K",
                uniforms: u1,
                additionalNodeInputs: []
            ),
            inputs: [.source],
            outputSpec: .sameAsSource,
            isFinal: false,
            debugLabel: "n1"
        )
        let final = Fx.pixelLocalNode(id: 2, bodyName: "F",
                                      input: .node(0),
                                      isFinal: true,
                                      additionalNodeInputs: [.node(1)])
        let g = PipelineGraph(nodes: [n0, n1, final], totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 3)
    }

    /// Same uniform bytes: must fold.
    func testIdenticalUniformBytesFold() {
        struct TestU { var value: Float }
        let u0 = FilterUniforms(TestU(value: 0.5))
        let u1 = FilterUniforms(TestU(value: 0.5))

        let n0 = Node(
            id: 0,
            kind: .nativeCompute(
                kernelName: "K",
                uniforms: u0,
                additionalNodeInputs: []
            ),
            inputs: [.source],
            outputSpec: .sameAsSource,
            isFinal: false,
            debugLabel: "n0"
        )
        let n1 = Node(
            id: 1,
            kind: .nativeCompute(
                kernelName: "K",
                uniforms: u1,
                additionalNodeInputs: []
            ),
            inputs: [.source],
            outputSpec: .sameAsSource,
            isFinal: false,
            debugLabel: "n1"
        )
        let final = Fx.pixelLocalNode(id: 2, bodyName: "F",
                                      input: .node(0),
                                      isFinal: true,
                                      additionalNodeInputs: [.node(1)])
        let g = PipelineGraph(nodes: [n0, n1, final], totalAdditionalInputs: 0)
        let out = pass.run(g)
        XCTAssertEqual(out.nodes.count, 2, "Identical uniforms fold")
        XCTAssertEqual(out.nodes.first { $0.id == 2 }?.inputs, [.node(0)])
        // The auxiliary ref should also be remapped to the surviving 0.
        if case let .pixelLocal(_, _, _, aux) = out.nodes.first(where: { $0.id == 2 })?.kind {
            XCTAssertEqual(aux, [.node(0)])
        } else {
            XCTFail("Expected pixelLocal final")
        }
    }

    // MARK: - Pass name

    func testPassNameIsStable() {
        XCTAssertEqual(pass.name, "CSE")
    }
}
