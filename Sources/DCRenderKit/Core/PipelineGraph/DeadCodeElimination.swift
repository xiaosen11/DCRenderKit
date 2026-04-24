//
//  DeadCodeElimination.swift
//  DCRenderKit
//
//  Phase-2 optimiser pass 1. Walks the graph backward from the
//  final node, marks every node reachable via `dependencyRefs`,
//  and drops the rest. Typical sources of dead nodes:
//
//    · identity-parameter filters that lowering kept as a placeholder
//      (lowering itself skips them, but the pass exists as a belt-
//      and-suspenders guard for future lowering paths);
//    · CSE-collapsed duplicates (Phase-2 pass 3) whose originating
//      node becomes an orphan;
//    · VerticalFusion / TailSink outputs whose former members stop
//      being referenced after fusion;
//    · Future rewrites that produce unreachable nodes by design.
//
//  DCE is the first pass in the sequence so later passes see a
//  minimal graph; it's also cheap (O(V + E) with standard BFS), so
//  the cost of running it even on graphs with no dead nodes is
//  negligible.
//

import Foundation

/// Remove nodes unreachable from the graph's final node.
///
/// ## Algorithm
///
/// 1. Seed the reachable set with `graph.finalID`.
/// 2. BFS backward: for each frontier node, add every
///    `NodeRef.node(_)` in its `dependencyRefs` to the reachable
///    set (if not already present).
/// 3. Drop nodes whose id is not in the reachable set.
///
/// `NodeRef.source` and `NodeRef.additional(_)` do not point at
/// nodes, so they don't contribute to reachability. A graph in
/// which every node is reachable is returned unchanged.
@available(iOS 18.0, *)
internal struct DeadCodeElimination: OptimizerPass {

    let name = "DCE"

    func run(_ graph: PipelineGraph) -> PipelineGraph {
        let byID: [NodeID: Node] = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
        )

        var reachable: Set<NodeID> = [graph.finalID]
        var frontier: [NodeID] = [graph.finalID]

        while !frontier.isEmpty {
            var next: [NodeID] = []
            for nodeID in frontier {
                guard let node = byID[nodeID] else { continue }
                for ref in node.dependencyRefs {
                    if case .node(let depID) = ref {
                        if reachable.insert(depID).inserted {
                            next.append(depID)
                        }
                    }
                }
            }
            frontier = next
        }

        // If every node is reachable, the graph is already minimal
        // and we avoid reconstructing it.
        if reachable.count == graph.nodes.count {
            return graph
        }

        let live = graph.nodes.filter { reachable.contains($0.id) }
        return PipelineGraph(
            nodes: live,
            totalAdditionalInputs: graph.totalAdditionalInputs
        )
    }
}
