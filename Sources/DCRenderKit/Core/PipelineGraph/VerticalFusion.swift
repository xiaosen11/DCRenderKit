//
//  VerticalFusion.swift
//  DCRenderKit
//
//  Phase-2 optimiser pass 2. Walks the graph in declaration order
//  and merges runs of adjacent `.pixelLocal` nodes whose outputs
//  flow straight into the next `.pixelLocal` node — no fan-out, no
//  resolution change, same `wantsLinearInput` — into a single
//  `.fusedPixelLocalCluster` node. The cluster's members execute
//  in order inside the uber kernel Phase 3 generates, passing
//  pixel data between each other via shader-local registers
//  instead of intermediate textures.
//
//  Correctness relies on the per-pixel determinism of every body
//  function: `DCRExposureBody(rgb, u0)` followed by
//  `DCRContrastBody(rgb, u1)` inside one kernel produces the same
//  pixel as running the two kernels back-to-back with a
//  `rgba16Float` intermediate, up to the Float16 rounding floor
//  (verified by Phase-3 legacy-parity tests).
//
//  See `docs/pipeline-compiler-design.md` §5.2 for the fusion
//  conditions and §5.5 for the aggressive tail sink that can, in
//  Phase 2 step 5, consume the cluster's trailing member into an
//  adjacent multi-pass filter's final pass.
//

import Foundation

/// Merge runs of adjacent pixel-local nodes into single fused
/// clusters.
///
/// ## Conditions for merging two adjacent nodes `A → B`
///
/// All four must hold:
///
/// 1. Both are `.pixelLocal`.
/// 2. `B.inputs == [.node(A.id)]` — B's only texture input is A's
///    output, and it enters at the primary slot.
/// 3. `A.outputSpec == .sameAsSource` **and** `B.outputSpec ==
///    .sameAsSource` — no resolution change between A and B.
/// 4. `A.wantsLinearInput == B.wantsLinearInput` — both bodies
///    expect the same colour-space representation; mixing would
///    require a gamma wrapper the uber kernel can't elide.
///
/// ### Fan-out guard
///
/// Condition 2's "B's only texture input is A's output" implies
/// B doesn't also read A via an auxiliary slot. The pass
/// additionally requires that A has **exactly one consumer** across
/// the whole graph — namely B. If any other node reads `.node(A.id)`,
/// merging would force the cluster to re-emit A's output, defeating
/// the point of fusion. A `finalID` node is also excluded because
/// its output is externally observed.
///
/// Clusters of length 1 (single pixel-local node not eligible for
/// merging) are left unchanged; they'd add indirection without
/// benefit. The optimiser returns the input graph verbatim when it
/// merges nothing.
@available(iOS 18.0, *)
internal struct VerticalFusion: OptimizerPass {

    let name = "VerticalFusion"

    func run(_ graph: PipelineGraph) -> PipelineGraph {
        // Count how many other nodes read each node's output.
        // Needed for the fan-out guard — A is only mergeable if it
        // has exactly one consumer (the B we're trying to merge it
        // into) and isn't the final node.
        let consumerCount = graph.consumerCounts()

        var newNodes: [Node] = []
        var remap: [NodeID: NodeID] = [:]
        var nextNewID = (graph.nodes.map { $0.id }.max() ?? -1) + 1
        var i = 0

        while i < graph.nodes.count {
            let head = graph.nodes[i]

            guard
                case let .pixelLocal(_, _, wantsLinear, _) = head.kind,
                head.outputSpec == .sameAsSource
            else {
                newNodes.append(head)
                i += 1
                continue
            }

            // Try to extend the cluster greedily past `head`.
            var cluster: [Node] = [head]
            var j = i + 1
            while j < graph.nodes.count {
                let prev = cluster.last!
                let cand = graph.nodes[j]

                guard canMerge(
                    prev: prev,
                    candidate: cand,
                    clusterWantsLinear: wantsLinear,
                    consumerCount: consumerCount
                ) else {
                    break
                }

                cluster.append(cand)
                j += 1
            }

            if cluster.count >= 2 {
                let fused = buildClusterNode(
                    cluster: cluster,
                    wantsLinear: wantsLinear,
                    assignedID: nextNewID
                )
                for member in cluster {
                    remap[member.id] = nextNewID
                }
                nextNewID += 1
                newNodes.append(fused)
            } else {
                newNodes.append(head)
            }
            i = j
        }

        // If nothing merged, avoid reconstructing the graph.
        if remap.isEmpty {
            return graph
        }

        // Rewrite any NodeRef pointing at a merged-away node to the
        // new cluster id. The fan-out guard already ensures only the
        // node immediately preceding the cluster's next member reads
        // the cluster's internal nodes (and those edges are gone,
        // having been absorbed into the cluster), but the remap is
        // cheap and defends against future optimisations that might
        // relax guard invariants.
        let rewritten = newNodes.map { remapRefs($0, using: remap) }

        return PipelineGraph(
            nodes: rewritten,
            totalAdditionalInputs: graph.totalAdditionalInputs
        )
    }

    // MARK: - Merge condition

    private func canMerge(
        prev: Node,
        candidate: Node,
        clusterWantsLinear: Bool,
        consumerCount: [NodeID: Int]
    ) -> Bool {
        // prev must have exactly one consumer (the candidate) and
        // must not be the pipeline's final output.
        if prev.isFinal { return false }
        if (consumerCount[prev.id] ?? 0) != 1 { return false }

        // candidate must also be pixelLocal with a matching colour
        // space preference and unchanged output spec.
        guard case let .pixelLocal(candBody, _, candLinear, _) = candidate.kind else {
            return false
        }
        if candLinear != clusterWantsLinear { return false }
        if candidate.outputSpec != .sameAsSource { return false }

        // Candidate's sole primary input must be the prev node.
        // This rejects neighborhood-style multi-input bodies and any
        // future `.pixelLocal` that reads the source alongside a
        // prior node.
        guard candidate.inputs == [.node(prev.id)] else { return false }

        // Both prev and candidate must share the same signature
        // shape. Mixing shapes inside a cluster would require the
        // uber-kernel builder to generate per-member call sites
        // with different parameter lists (e.g. one member wanting
        // only `(rgb, u)` and the next wanting `(rgb, u, gid,
        // lut)`). The Phase-3 codegen for clusters only emits a
        // single uniform call convention, so cross-shape fusion is
        // deferred to a later pass.
        guard
            case let .pixelLocal(prevBody, _, _, _) = prev.kind,
            prevBody.signatureShape == candBody.signatureShape
        else {
            return false
        }

        // Even if both members share a shape, the compute-path
        // cluster codegen (`MetalSourceBuilder.buildFusedPixelLocal
        // Cluster`) only emits the `body(rgb, u)` call form. A
        // cluster of, say, two `.pixelLocalWithLUT3D` filters would
        // pass the same-shape guard above but throw
        // `unsupportedSignatureShape` at dispatch time — which the
        // runtime surfaces as "command encoder released without
        // endEncoding" plus a CPU spike (the failed compile retries
        // every frame). This is the same root cause as
        // `TailSink`'s cluster-absorption guard (TailSink.swift:140),
        // applied at fusion-creation time instead of fusion-extension
        // time. Filters that carry additional textures or `gid`
        // remain dispatchable as standalone nodes; the fragment-
        // chain path can still batch them via programmable blending.
        guard candBody.signatureShape.canFuseAsPixelLocalMember else {
            return false
        }

        return true
    }

    // MARK: - Cluster construction

    private func buildClusterNode(
        cluster: [Node],
        wantsLinear: Bool,
        assignedID: NodeID
    ) -> Node {
        // Head's inputs become the cluster's inputs.
        let clusterInputs = cluster[0].inputs

        // Last member determines isFinal and outputSpec (always
        // sameAsSource given the merge condition).
        let isFinal = cluster.last!.isFinal
        let outputSpec = cluster.last!.outputSpec

        // Build the union of additional texture refs across
        // members, preserving member order. Each member records a
        // Range<Int> into this union so Phase-3 codegen can assign
        // one texture binding per member.
        var unionAdditional: [NodeRef] = []
        var members: [FusedClusterMember] = []
        members.reserveCapacity(cluster.count)
        for node in cluster {
            guard case let .pixelLocal(body, uniforms, _, aux) = node.kind else {
                // Unreachable by construction (canMerge gates on
                // .pixelLocal). Invariant.check surfaces violations
                // in debug without crashing release.
                Invariant.check(
                    false,
                    "VerticalFusion cluster contained non-pixelLocal node \(node.id)"
                )
                continue
            }
            let start = unionAdditional.count
            unionAdditional.append(contentsOf: aux)
            let end = unionAdditional.count
            members.append(FusedClusterMember(
                body: body,
                uniforms: uniforms,
                debugLabel: node.debugLabel,
                additionalRange: start..<end
            ))
        }

        let label = "FusedCluster[\(cluster.first!.debugLabel)..\(cluster.last!.debugLabel)]"

        return Node(
            id: assignedID,
            kind: .fusedPixelLocalCluster(
                members: members,
                wantsLinearInput: wantsLinear,
                additionalNodeInputs: unionAdditional
            ),
            inputs: clusterInputs,
            outputSpec: outputSpec,
            isFinal: isFinal,
            debugLabel: label
        )
    }

    // MARK: - Helpers

    /// Rewrite any `NodeRef.node(oldID)` in the node's inputs /
    /// kind-specific auxiliary refs according to `using`. Node
    /// fields not referencing node IDs (outputSpec, uniforms,
    /// wantsLinearInput) pass through.
    private func remapRefs(_ node: Node, using remap: [NodeID: NodeID]) -> Node {
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
        // Use `withReplacedRefs` (not `Node.init`) so the optimiser
        // markers `inlinedBodyBeforeSample` / `tailSinkedBody` (and
        // any future field on Node) propagate through unchanged.
        // VF runs before KI / TailSink in the default pass order so
        // those markers are nil today; the helper makes the rewrite
        // robust against future pass-order changes.
        return node.withReplacedRefs(kind: remappedKind, inputs: remappedInputs)
    }

    private func remapSingle(_ ref: NodeRef, using remap: [NodeID: NodeID]) -> NodeRef {
        if case .node(let id) = ref, let newID = remap[id] {
            return .node(newID)
        }
        return ref
    }
}
