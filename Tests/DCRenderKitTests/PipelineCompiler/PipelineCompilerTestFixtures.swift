//
//  PipelineCompilerTestFixtures.swift
//  DCRenderKitTests
//
//  Shared helpers for the Phase-2 optimiser-pass tests. Keeps every
//  individual pass test file focused on the transformation it
//  exercises rather than re-implementing node-construction
//  boilerplate.
//

import Foundation
@testable import DCRenderKit

@available(iOS 18.0, *)
enum PipelineCompilerTestFixtures {

    // MARK: - FusionBody placeholders

    /// Minimal `FusionBody` suitable for pass tests — the tests
    /// never resolve the URL or dispatch the body, so real shader
    /// metadata is unnecessary.
    static func dummyBody(
        _ functionName: String,
        kind: FusionNodeKind = .pixelLocal,
        wantsLinearInput: Bool = false
    ) -> FusionBody {
        FusionBody(
            functionName: functionName,
            uniformStructName: "\(functionName)Uniforms",
            kind: kind,
            wantsLinearInput: wantsLinearInput,
            sourceMetalFile: URL(fileURLWithPath: "/dev/null/\(functionName).metal")
        )
    }

    // MARK: - Node constructors

    /// Build a pixel-local node whose only dependency is `input`.
    static func pixelLocalNode(
        id: NodeID,
        bodyName: String,
        input: NodeRef = .source,
        isFinal: Bool = false,
        wantsLinearInput: Bool = false,
        additionalNodeInputs: [NodeRef] = [],
        label: String? = nil
    ) -> Node {
        Node(
            id: id,
            kind: .pixelLocal(
                body: dummyBody(bodyName, kind: .pixelLocal, wantsLinearInput: wantsLinearInput),
                uniforms: .empty,
                wantsLinearInput: wantsLinearInput,
                additionalNodeInputs: additionalNodeInputs
            ),
            inputs: [input],
            outputSpec: .sameAsSource,
            isFinal: isFinal,
            debugLabel: label ?? "n\(id)_\(bodyName)"
        )
    }

    /// Build a neighbour-read node. `radius` threads through as the
    /// kind's radius hint and matches the body-descriptor kind.
    static func neighborReadNode(
        id: NodeID,
        bodyName: String,
        radius: Int,
        input: NodeRef = .source,
        additionalNodeInputs: [NodeRef] = [],
        isFinal: Bool = false,
        label: String? = nil
    ) -> Node {
        Node(
            id: id,
            kind: .neighborRead(
                body: dummyBody(bodyName, kind: .neighborRead(radius: radius)),
                uniforms: .empty,
                radiusHint: radius,
                additionalNodeInputs: additionalNodeInputs
            ),
            inputs: [input],
            outputSpec: .sameAsSource,
            isFinal: isFinal,
            debugLabel: label ?? "n\(id)_\(bodyName)"
        )
    }

    /// Build a native-compute node wrapping an opaque kernel name.
    static func nativeComputeNode(
        id: NodeID,
        kernelName: String,
        input: NodeRef = .source,
        additionalNodeInputs: [NodeRef] = [],
        isFinal: Bool = false,
        outputSpec: TextureSpec = .sameAsSource,
        label: String? = nil
    ) -> Node {
        Node(
            id: id,
            kind: .nativeCompute(
                kernelName: kernelName,
                uniforms: .empty,
                additionalNodeInputs: additionalNodeInputs
            ),
            inputs: [input],
            outputSpec: outputSpec,
            isFinal: isFinal,
            debugLabel: label ?? "n\(id)_\(kernelName)"
        )
    }

    // MARK: - Graph constructors

    /// A linear chain of pixel-local nodes of the requested length.
    /// Node 0 reads `.source`, every later node reads the previous
    /// node's output, and the last node is marked final.
    static func linearPixelLocalChain(length: Int) -> PipelineGraph {
        precondition(length > 0, "linearPixelLocalChain needs at least one node")
        var nodes: [Node] = []
        for i in 0..<length {
            let input: NodeRef = (i == 0) ? .source : .node(i - 1)
            nodes.append(pixelLocalNode(
                id: i,
                bodyName: "Body\(i)",
                input: input,
                isFinal: (i == length - 1)
            ))
        }
        return PipelineGraph(nodes: nodes, totalAdditionalInputs: 0)
    }

    /// Build a PipelineGraph bypassing validation. Only use this
    /// for validator tests that need a deliberately malformed
    /// graph — production code must route through the designated
    /// initialiser.
    static func bypassingValidation(
        _ nodes: [Node],
        totalAdditionalInputs: Int
    ) -> PipelineGraph {
        PipelineGraph(
            _testInvalidNodes: nodes,
            totalAdditionalInputs: totalAdditionalInputs
        )
    }
}
