//
//  CommonSubexpressionElimination.swift
//  DCRenderKit
//
//  Phase-2 optimiser pass 3. Folds duplicate nodes — two nodes
//  with the same `NodeSignature` produce the same output, so the
//  second one can be rewritten to reference the first. Typical
//  real-world trigger: `HighlightShadowFilter` and `ClarityFilter`
//  both emit a `DCRGuidedDownsampleLuma` pass as their first
//  step; when both are in the same pipeline, CSE collapses those
//  two downsamples into one node that both filters' later passes
//  read from.
//

import Foundation

/// Remove duplicate computation by folding nodes with identical
/// signatures.
///
/// ## Algorithm
///
/// 1. Walk nodes in declaration order.
/// 2. For each node, compute `Node.signature`. A `nil` signature
///    (currently only `.fusedPixelLocalCluster`) means "don't
///    participate" — the node is kept verbatim.
/// 3. If the signature is already in the seen map, add the current
///    node's id → earlier node's id into the remap and drop it
///    from the survivors.
/// 4. Otherwise record the signature → id mapping and keep the
///    node.
/// 5. After the scan, rewrite every surviving node's `NodeRef`s to
///    replace folded-away ids with their representatives.
///
/// `isFinal` nodes are never folded — they'd become unreachable
/// (graph must have exactly one final), and swapping a non-final
/// node's role with a final's would require a more sophisticated
/// analysis. Excluding them is both simpler and safe: the final
/// node is at the end of the chain by construction, so it's an
/// unlikely CSE target anyway.
///
/// `.fusedPixelLocalCluster` nodes are also excluded (signature
/// returns nil). Clusters are themselves fusion products; re-CSE-
/// ing them would require element-wise member equality that the
/// signature doesn't capture today.
@available(iOS 18.0, *)
internal struct CommonSubexpressionElimination: OptimizerPass {

    let name = "CSE"

    func run(_ graph: PipelineGraph) -> PipelineGraph {
        var seen: [NodeSignature: NodeID] = [:]
        var remap: [NodeID: NodeID] = [:]
        var keepIDs: [NodeID] = []
        var kept: Set<NodeID> = []

        for node in graph.nodes {
            // Final nodes never fold away.
            if node.isFinal {
                kept.insert(node.id)
                keepIDs.append(node.id)
                continue
            }

            guard let sig = node.signature else {
                kept.insert(node.id)
                keepIDs.append(node.id)
                continue
            }

            if let existing = seen[sig] {
                remap[node.id] = existing
                // Node dropped; do NOT append to keepIDs.
            } else {
                seen[sig] = node.id
                kept.insert(node.id)
                keepIDs.append(node.id)
            }
        }

        if remap.isEmpty {
            return graph
        }

        // Preserve original declaration order of survivors.
        let survivors = graph.nodes
            .filter { kept.contains($0.id) }
            .map { rewriteRefs($0, using: remap) }

        return PipelineGraph(
            nodes: survivors,
            totalAdditionalInputs: graph.totalAdditionalInputs
        )
    }

    // MARK: - NodeRef rewriting

    private func rewriteRefs(_ node: Node, using remap: [NodeID: NodeID]) -> Node {
        let remappedInputs = node.inputs.map { remapSingle($0, using: remap) }
        let remappedKind: NodeKind
        switch node.kind {
        case .pixelLocal(let body, let uniforms, let linear, let aux):
            remappedKind = .pixelLocal(
                body: body,
                uniforms: uniforms,
                wantsLinearInput: linear,
                additionalNodeInputs: aux.map { remapSingle($0, using: remap) }
            )
        case .neighborRead(let body, let uniforms, let r, let aux):
            remappedKind = .neighborRead(
                body: body,
                uniforms: uniforms,
                radiusHint: r,
                additionalNodeInputs: aux.map { remapSingle($0, using: remap) }
            )
        case .nativeCompute(let kernel, let uniforms, let aux):
            remappedKind = .nativeCompute(
                kernelName: kernel,
                uniforms: uniforms,
                additionalNodeInputs: aux.map { remapSingle($0, using: remap) }
            )
        case .fusedPixelLocalCluster(let members, let linear, let aux):
            remappedKind = .fusedPixelLocalCluster(
                members: members,
                wantsLinearInput: linear,
                additionalNodeInputs: aux.map { remapSingle($0, using: remap) }
            )
        case .blend(let op, let aux):
            remappedKind = .blend(op: op, aux: remapSingle(aux, using: remap))
        case .downsample, .upsample, .reduce:
            remappedKind = node.kind
        }
        return Node(
            id: node.id,
            kind: remappedKind,
            inputs: remappedInputs,
            outputSpec: node.outputSpec,
            isFinal: node.isFinal,
            debugLabel: node.debugLabel
        )
    }

    private func remapSingle(_ ref: NodeRef, using remap: [NodeID: NodeID]) -> NodeRef {
        if case .node(let id) = ref, let newID = remap[id] {
            return .node(newID)
        }
        return ref
    }
}
