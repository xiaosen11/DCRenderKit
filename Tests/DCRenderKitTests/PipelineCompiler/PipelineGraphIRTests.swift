//
//  PipelineGraphIRTests.swift
//  DCRenderKitTests
//
//  Exercises the Phase-1 IR types — `Node`, `NodeKind`, `NodeRef`,
//  `PipelineGraph`, and the auxiliary enums. These tests do not
//  dispatch anything to the GPU; they verify the structural
//  invariants that the lowering pass (later step in Phase 1) and the
//  optimiser (Phase 2) will rely on.
//

import XCTest
@testable import DCRenderKit

@available(iOS 18.0, *)
final class PipelineGraphIRTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal `FusionBody` for tests that just need a concrete body
    /// payload. Not a real shader reference — graph validation does
    /// not resolve URLs.
    private func dummyBody(
        _ name: String,
        uniformStruct: String = "DummyUniforms"
    ) -> FusionBody {
        FusionBody(
            functionName: name,
            uniformStructName: uniformStruct,
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceMetalFile: URL(fileURLWithPath: "/dev/null/\(name).metal")
        )
    }

    /// Build a linear pixel-local chain of `n` nodes consuming the
    /// source and chaining each to the next; the last is marked
    /// final. Returns (graph, nodeIDs).
    private func linearPixelLocalChain(length n: Int) -> PipelineGraph {
        precondition(n > 0, "linearPixelLocalChain needs at least one node")
        var nodes: [Node] = []
        for i in 0..<n {
            let input: NodeRef = i == 0 ? .source : .node(i - 1)
            nodes.append(Node(
                id: i,
                kind: .pixelLocal(
                    body: dummyBody("DCRBody\(i)"),
                    uniforms: .empty,
                    wantsLinearInput: false,
                    additionalNodeInputs: []
                ),
                inputs: [input],
                outputSpec: .sameAsSource,
                isFinal: (i == n - 1),
                debugLabel: "Node\(i)"
            ))
        }
        return PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
    }

    // MARK: - NodeRef invariants

    /// `NodeRef` is `Hashable` so optimiser passes (CSE, DCE) can
    /// compare references via set membership. Verify the hashing
    /// distinguishes the three variants that look similar.
    func testNodeRefHashableDistinguishesSourceFromNode0() {
        let refs: Set<NodeRef> = [.source, .node(0), .additional(0)]
        XCTAssertEqual(refs.count, 3)
    }

    // MARK: - PipelineGraph valid construction

    /// A 3-node linear pixel-local chain is valid. The final id is
    /// set correctly; dump contains one line per node and flags the
    /// final.
    func testLinearChainValidates() {
        let g = linearPixelLocalChain(length: 3)
        XCTAssertEqual(g.nodes.count, 3)
        XCTAssertEqual(g.finalID, 2)
        XCTAssertTrue(g.dump.contains("*final*"))
        XCTAssertEqual(g.dump.components(separatedBy: "\n").count, 3)
    }

    /// Single-node graph: source → pixelLocal → final.
    func testSingleNodeGraphValidates() {
        let g = linearPixelLocalChain(length: 1)
        XCTAssertEqual(g.nodes.count, 1)
        XCTAssertEqual(g.finalID, 0)
        XCTAssertTrue(g.nodes[0].isFinal)
    }

    // MARK: - validate() rejects malformed graphs

    /// No `isFinal` → invariant violation. Construction traps in
    /// debug, so we exercise `validate()` directly on a
    /// handcrafted `PipelineGraph` bypassing the init.
    func testValidateRejectsZeroFinal() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(
                    body: dummyBody("A"),
                    uniforms: .empty,
                    wantsLinearInput: false,
                    additionalNodeInputs: []
                ),
                inputs: [.source],
                outputSpec: .sameAsSource,
                isFinal: false,
                debugLabel: "A"
            )
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "expected exactly one isFinal=true node")
        }
    }

    /// Two `isFinal` → invariant violation.
    func testValidateRejectsMultipleFinals() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .sameAsSource,
                isFinal: true,
                debugLabel: "A"
            ),
            Node(
                id: 1,
                kind: .pixelLocal(body: dummyBody("B"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.node(0)],
                outputSpec: .sameAsSource,
                isFinal: true,
                debugLabel: "B"
            ),
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "got 2")
        }
    }

    /// Forward reference — node 0 references node 1 before 1 is
    /// declared — is rejected.
    func testValidateRejectsForwardReference() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.node(1)],         // forward ref
                outputSpec: .sameAsSource,
                isFinal: false,
                debugLabel: "A"
            ),
            Node(
                id: 1,
                kind: .pixelLocal(body: dummyBody("B"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .sameAsSource,
                isFinal: true,
                debugLabel: "B"
            ),
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "not declared earlier")
        }
    }

    /// Self-reference (node references its own id) is rejected.
    func testValidateRejectsSelfReference() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.node(0)],
                outputSpec: .sameAsSource,
                isFinal: true,
                debugLabel: "A"
            )
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "references itself")
        }
    }

    /// Duplicate ids are rejected.
    func testValidateRejectsDuplicateIDs() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .sameAsSource,
                isFinal: false,
                debugLabel: "A"
            ),
            Node(
                id: 0,                                   // duplicate
                kind: .pixelLocal(body: dummyBody("B"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .sameAsSource,
                isFinal: true,
                debugLabel: "B"
            ),
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "duplicate node id")
        }
    }

    /// `.additional(i)` with `i` outside the declared count is
    /// rejected. This is the guard that catches `MultiPassFilter`
    /// auxiliary-texture mis-indexing at lowering time rather than
    /// at Metal dispatch time.
    func testValidateRejectsOutOfRangeAdditional() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .neighborRead(
                    body: dummyBody("N"),
                    uniforms: .empty,
                    radiusHint: 1,
                    additionalNodeInputs: [.additional(3)]    // bogus
                ),
                inputs: [.source],
                outputSpec: .sameAsSource,
                isFinal: true,
                debugLabel: "N"
            )
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 1)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: ".additional(3)")
        }
    }

    /// Explicit dimensions must be positive.
    func testValidateRejectsNonPositiveExplicitDimensions() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .explicit(width: 0, height: 100),
                isFinal: true,
                debugLabel: "A"
            )
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "non-positive explicit dimensions")
        }
    }

    /// `scaled(factor:)` must be positive.
    func testValidateRejectsNonPositiveScaleFactor() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .scaled(factor: 0),
                isFinal: true,
                debugLabel: "A"
            )
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "non-positive scale factor")
        }
    }

    /// `.matching(peer)` referencing a non-existent earlier node
    /// label is rejected.
    func testValidateRejectsMatchingUnknownPeer() throws {
        let nodes = [
            Node(
                id: 0,
                kind: .pixelLocal(body: dummyBody("A"), uniforms: .empty, wantsLinearInput: false, additionalNodeInputs: []),
                inputs: [.source],
                outputSpec: .matching(passName: "NoSuchPeer"),
                isFinal: true,
                debugLabel: "A"
            )
        ]
        let g = makeGraphBypassingInit(nodes: nodes, totalAdditionalInputs: 0)
        XCTAssertThrowsError(try g.validate()) { error in
            assertInvalidPassGraph(error, reasonContains: "NoSuchPeer")
        }
    }

    // MARK: - dump shape

    /// Dump is one line per node; pixelLocal dump carries the body
    /// function name and `linear` flag.
    func testDumpShapePixelLocal() {
        let g = linearPixelLocalChain(length: 2)
        let lines = g.dump.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("DCRBody0"))
        XCTAssertTrue(lines[0].contains("linear=false"))
        XCTAssertTrue(lines[1].contains("*final*"))
    }

    // MARK: - Private helpers

    /// Build a `PipelineGraph` bypassing the `validate()` pre-check
    /// in the designated initialiser. The production path always
    /// goes through that initialiser (which traps on invariant
    /// violations); validator tests need to feed it a deliberately
    /// broken graph and observe the thrown error, so they route
    /// through the `_testInvalidNodes:` bypass exposed for this
    /// exact purpose (see `PipelineGraph.init(_testInvalidNodes:...)`).
    private func makeGraphBypassingInit(
        nodes: [Node],
        totalAdditionalInputs: Int
    ) -> PipelineGraph {
        PipelineGraph(
            _testInvalidNodes: nodes,
            totalAdditionalInputs: totalAdditionalInputs
        )
    }

    private func assertInvalidPassGraph(
        _ error: Error,
        reasonContains substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let PipelineError.filter(.invalidPassGraph(_, reason)) = error else {
            XCTFail(
                "Expected PipelineError.filter(.invalidPassGraph), got \(error)",
                file: file, line: line
            )
            return
        }
        XCTAssertTrue(
            reason.contains(substring),
            "Expected reason to contain \"\(substring)\", got \"\(reason)\"",
            file: file, line: line
        )
    }
}
