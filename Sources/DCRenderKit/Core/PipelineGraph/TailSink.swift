//
//  TailSink.swift
//  DCRenderKit
//
//  Phase-2 optimiser pass 5 — aggressive tail-side fusion. Where
//  `KernelInlining` (pass 4) absorbs an upstream `.pixelLocal` into
//  a downstream `.neighborRead`, TailSink does the opposite: it
//  absorbs a downstream `.pixelLocal` into its upstream producer,
//  so the producer's own kernel applies the pixelLocal body right
//  before `output.write` runs.
//
//  The "aggressive" variant (see `docs/pipeline-compiler-design.md`
//  §5.5, decision Q3): TailSink sinks across more than just
//  pixelLocal-to-pixelLocal boundaries. In particular, a
//  `.fusedPixelLocalCluster` can absorb a pixelLocal successor by
//  extending its `members` array, and a `.neighborRead` node can
//  tag its trailing sink on `Node.tailSinkedBody` for Phase-3
//  codegen to splice into the write path. `.nativeCompute`
//  successors are skipped because the compiler can't modify an
//  opaque kernel's write logic.
//
//  The pass is worth running after `VerticalFusion` +
//  `KernelInlining` / `CSE` because those earlier passes expose
//  new TailSink opportunities by producing clusters and by
//  folding duplicates.
//

import Foundation

/// Absorb a downstream tail `.pixelLocal` into its producer's
/// write path.
///
/// ## Merge conditions
///
/// Let `M` be the producer and `P` be the downstream pixel-local
/// consumer. All of the following must hold:
///
/// 1. `P.kind == .pixelLocal`, `P.outputSpec == .sameAsSource`,
///    and `P.inlinedBodyBeforeSample == nil` (no prior head fuse to
///    relocate).
/// 2. `P.inputs == [.node(M.id)]` — P reads M directly and
///    nothing else.
/// 3. `M` has exactly one consumer (namely P).
/// 4. **`P` has no consumers** — P must be a graph leaf
///    (typically `isFinal == true`). When P is non-final but
///    still has downstream consumers (common when a multi-pass
///    filter's later passes reference an earlier pixelLocal-style
///    intermediate by `NodeRef.node(P.id)`), absorbing P into M
///    would drop P's id from the graph and leave dangling
///    references — the validator at `PipelineGraph.init` rejects
///    these as "node X references Y which is not declared
///    earlier" with a fatal error.
/// 5. `M.outputSpec == P.outputSpec == .sameAsSource` — no
///    resolution change across the boundary.
/// 6. `M.kind` is one of `.fusedPixelLocalCluster` or
///    `.neighborRead`. `.pixelLocal` producers are already handled
///    by `VerticalFusion`; `.nativeCompute` producers are opaque
///    to the codegen and therefore skipped.
/// 7. `M.tailSinkedBody == nil` — no double-sinking yet.
///
/// When the conditions hold:
///
/// - `.fusedPixelLocalCluster`: P is appended as a new
///   `FusedClusterMember` with its auxiliary range pointing at
///   the tail of the (possibly grown) cluster-level aux union.
/// - `.neighborRead`: P is captured in `Node.tailSinkedBody` with
///   the same range-into-aux convention. The neighbour-read's
///   `additionalNodeInputs` are extended with P's auxiliaries.
///
/// P is then dropped from the graph.
@available(iOS 18.0, *)
internal struct TailSink: OptimizerPass {

    let name = "TailSink"

    func run(_ graph: PipelineGraph) -> PipelineGraph {
        let byID: [NodeID: Node] = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
        )
        let consumerCount = computeConsumerCount(graph)

        var replacement: [NodeID: Node] = [:]
        var dropped: Set<NodeID> = []

        for node in graph.nodes {
            // We want `node == P` (the downstream pixelLocal).
            guard
                case let .pixelLocal(pBody, pUniforms, _, pAux) = node.kind,
                node.inlinedBodyBeforeSample == nil,
                node.outputSpec == .sameAsSource,
                let primary = node.inputs.first,
                case .node(let producerID) = primary,
                let producer = byID[producerID],
                // M's only consumer must be P — otherwise other downstream
                // nodes still see M's pre-absorption output and the merged
                // M+P kernel would change their input.
                (consumerCount[producerID] ?? 0) == 1,
                // P itself must have no consumers — i.e. be a graph leaf
                // (typically the final node). When P is non-final but
                // still consumed (common when a multi-pass filter's later
                // pass references an earlier pixelLocal intermediate via
                // NodeRef.node(P.id)), absorbing P into M would drop P's
                // id from the graph and leave dangling references that
                // PipelineGraph.init rejects as "node X references Y
                // which is not declared earlier".
                (consumerCount[node.id] ?? 0) == 0,
                producer.outputSpec == .sameAsSource,
                producer.tailSinkedBody == nil
            else {
                continue
            }

            // Don't double-transform a producer we already
            // scheduled to sink another P into.
            if replacement[producerID] != nil || dropped.contains(producerID) {
                continue
            }

            switch producer.kind {
            case .fusedPixelLocalCluster:
                guard
                    case let .fusedPixelLocalCluster(members, wantsLinear, clusterAux) = producer.kind
                else { continue }

                let rangeStart = clusterAux.count
                let newAux = clusterAux + pAux
                let newMember = FusedClusterMember(
                    body: pBody,
                    uniforms: pUniforms,
                    debugLabel: node.debugLabel,
                    additionalRange: rangeStart..<(rangeStart + pAux.count)
                )

                let newCluster = Node(
                    id: producer.id,
                    kind: .fusedPixelLocalCluster(
                        members: members + [newMember],
                        wantsLinearInput: wantsLinear,
                        additionalNodeInputs: newAux
                    ),
                    inputs: producer.inputs,
                    outputSpec: producer.outputSpec,
                    isFinal: node.isFinal,
                    debugLabel: "\(producer.debugLabel)+\(node.debugLabel)",
                    inlinedBodyBeforeSample: producer.inlinedBodyBeforeSample,
                    tailSinkedBody: producer.tailSinkedBody
                )
                replacement[producer.id] = newCluster
                dropped.insert(node.id)

            case .neighborRead(let nBody, let nUniforms, let nRadius, let nAux):
                let rangeStart = nAux.count
                let combinedAux = nAux + pAux
                let sinked = FusedClusterMember(
                    body: pBody,
                    uniforms: pUniforms,
                    debugLabel: node.debugLabel,
                    additionalRange: rangeStart..<(rangeStart + pAux.count)
                )
                let newNeighbor = Node(
                    id: producer.id,
                    kind: .neighborRead(
                        body: nBody,
                        uniforms: nUniforms,
                        radiusHint: nRadius,
                        additionalNodeInputs: combinedAux
                    ),
                    inputs: producer.inputs,
                    outputSpec: producer.outputSpec,
                    isFinal: node.isFinal,
                    debugLabel: "\(producer.debugLabel)+\(node.debugLabel)",
                    inlinedBodyBeforeSample: producer.inlinedBodyBeforeSample,
                    tailSinkedBody: sinked
                )
                replacement[producer.id] = newNeighbor
                dropped.insert(node.id)

            // .pixelLocal producers → VerticalFusion already handled
            // .nativeCompute producers → codegen can't splice
            // (opaque kernel); skip.
            // Everything else (.downsample, .upsample, .reduce,
            // .blend) changes output shape or has special consumer
            // semantics — skip for Phase 2.
            default:
                continue
            }
        }

        if replacement.isEmpty && dropped.isEmpty {
            return graph
        }

        var survivors: [Node] = []
        survivors.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            if dropped.contains(node.id) { continue }
            if let rep = replacement[node.id] {
                survivors.append(rep)
            } else {
                survivors.append(node)
            }
        }

        return PipelineGraph(
            nodes: survivors,
            totalAdditionalInputs: graph.totalAdditionalInputs
        )
    }

    private func computeConsumerCount(_ graph: PipelineGraph) -> [NodeID: Int] {
        var counts: [NodeID: Int] = [:]
        for node in graph.nodes {
            for ref in node.dependencyRefs {
                if case .node(let id) = ref {
                    counts[id, default: 0] += 1
                }
            }
        }
        return counts
    }
}
