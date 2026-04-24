//
//  KernelInlining.swift
//  DCRenderKit
//
//  Phase-2 optimiser pass 4 (head fusion). Absorbs a `.pixelLocal`
//  producer into an immediately-downstream `.neighborRead`
//  consumer, so the neighbour-read kernel reads raw source pixels
//  and applies the inlined body to each sample — replacing two
//  dispatches (pixelLocal then neighborRead) and one intermediate
//  texture with a single, slightly heavier dispatch.
//
//  This pass is the spatial analogue of `VerticalFusion`: where
//  vertical fusion merges bodies that all touch the same pixel
//  coordinate, kernel inlining widens the neighbour-read's sample
//  loop so each sample pays the body's per-pixel cost before
//  combining. Phase 3's codegen consumes `Node.inlinedBodyBeforeSample`
//  and emits one kernel that loops over neighbours, applies the
//  inlined body to each read, and finally executes the
//  neighbour-read body.
//

import Foundation

/// Fold a single-consumer `.pixelLocal` predecessor into its
/// downstream `.neighborRead` node.
///
/// ## Merge conditions (all required)
///
/// 1. The downstream node (`N`) is `.neighborRead`.
/// 2. `N.inputs[0] == .node(P.id)` — the predecessor's output is
///    the neighbour-read's primary texture source.
/// 3. `P.kind == .pixelLocal`.
/// 4. `P.outputSpec == .sameAsSource`.
/// 5. `P.isFinal == false` (it would otherwise be observed externally).
/// 6. `P` has exactly one consumer in the whole graph (namely `N`).
/// 7. `N` doesn't already carry an inlined body (`inlinedBodyBeforeSample
///    == nil`) — double-inlining needs codegen support Phase 3 doesn't
///    ship.
///
/// When all seven hold, the pass:
///
/// - builds a `FusedClusterMember` describing `P`'s body / uniforms /
///   label / auxiliary range;
/// - appends `P`'s `additionalNodeInputs` onto `N`'s own, recording
///   the range so codegen knows which slots belong to the inlined
///   body versus the outer `N` body;
/// - rewrites `N.inputs[0]` to whatever `P` was reading (typically
///   `.source`), so the resulting node reads the true pipeline
///   source;
/// - drops `P` from the graph.
///
/// Two separate scans are used — the first identifies inline
/// opportunities, the second emits survivors — to avoid the
/// subtlety of modifying a graph we're still iterating over.
///
/// ## No-op conditions
///
/// Graphs without any neighbour-read-over-pixelLocal pattern pass
/// through unchanged. The pass is O(V + E).
@available(iOS 18.0, *)
internal struct KernelInlining: OptimizerPass {

    let name = "KernelInlining"

    func run(_ graph: PipelineGraph) -> PipelineGraph {
        let byID: [NodeID: Node] = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
        )
        let consumerCount = computeConsumerCount(graph)

        // Pass 1: identify inline opportunities.
        var replacement: [NodeID: Node] = [:]
        var dropped: Set<NodeID> = []

        for node in graph.nodes {
            guard
                case let .neighborRead(nBody, nUniforms, nRadius, nAux) = node.kind,
                node.inlinedBodyBeforeSample == nil,
                let primary = node.inputs.first,
                case .node(let predID) = primary,
                let pred = byID[predID],
                !pred.isFinal,
                (consumerCount[predID] ?? 0) == 1,
                pred.outputSpec == .sameAsSource,
                case let .pixelLocal(pBody, pUniforms, _, pAux) = pred.kind
            else {
                continue
            }

            // Stage P's auxiliary refs at the tail of N's union so
            // we can hand Phase 3 a contiguous slot map.
            let rangeStart = nAux.count
            let combinedAux = nAux + pAux
            let member = FusedClusterMember(
                body: pBody,
                uniforms: pUniforms,
                debugLabel: pred.debugLabel,
                additionalRange: rangeStart..<(rangeStart + pAux.count)
            )

            let rewritten = Node(
                id: node.id,
                kind: .neighborRead(
                    body: nBody,
                    uniforms: nUniforms,
                    radiusHint: nRadius,
                    additionalNodeInputs: combinedAux
                ),
                inputs: pred.inputs,
                outputSpec: node.outputSpec,
                isFinal: node.isFinal,
                debugLabel: "\(node.debugLabel)[inline:\(pred.debugLabel)]",
                inlinedBodyBeforeSample: member
            )
            replacement[node.id] = rewritten
            dropped.insert(predID)
        }

        if replacement.isEmpty {
            return graph
        }

        // Pass 2: emit the new node list, skipping dropped
        // predecessors and swapping inlined consumers in place.
        var survivors: [Node] = []
        survivors.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            if dropped.contains(node.id) { continue }
            if let rewritten = replacement[node.id] {
                survivors.append(rewritten)
            } else {
                survivors.append(node)
            }
        }

        return PipelineGraph(
            nodes: survivors,
            totalAdditionalInputs: graph.totalAdditionalInputs
        )
    }

    // MARK: - Helpers

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
