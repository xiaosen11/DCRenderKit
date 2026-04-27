//
//  PipelineGraph.swift
//  DCRenderKit
//
//  The container for a lowered pipeline IR. Holds an ordered list of
//  `Node` values plus enough metadata for the optimiser (Phase 2) and
//  backend codegen (Phase 3/7) to work without re-walking the
//  original `[AnyFilter]`.
//
//  Internal-only; no public API surface. See
//  `docs/pipeline-compiler-design.md` §3 for the IR design and
//  §1.2 for the rationale behind keeping the IR `internal`.
//

import Foundation

// MARK: - PipelineGraph

/// Immutable IR produced by the lowering pass. Every optimiser pass
/// takes a `PipelineGraph` and returns a new one; the original is
/// untouched. This makes it cheap to diff two graphs (`before` vs
/// `after` a pass) and safe to retain older snapshots for diagnostics.
///
/// Construction goes through `init(nodes:totalAdditionalInputs:)`
/// which runs `validate()` as a pre-condition: Phase-1 lowering is
/// expected to produce only valid graphs and an invalid graph
/// indicates a bug in the lowering or rewriter, not user input. For
/// that reason the initialiser traps on invariants via
/// `Invariant.unreachable`; the lowering entry point itself exposes
/// a throwing variant for diagnostic contexts.
internal struct PipelineGraph: Sendable {

    /// Nodes in declaration order. `inputs` that reference other
    /// nodes must refer to earlier entries in this array (the list
    /// is already a valid topological ordering).
    let nodes: [Node]

    /// Number of additional (non-primary) input textures the graph
    /// expects at execution time. This is the union of every
    /// `AnyFilter.multi(_).additionalInputs` count in the source
    /// `[AnyFilter]` plus any `AnyFilter.single(_).additionalInputs`
    /// threaded through. `NodeRef.additional(i)` with `i >=
    /// totalAdditionalInputs` is a hard invariant violation.
    let totalAdditionalInputs: Int

    /// ID of the single node with `isFinal == true`. Precomputed at
    /// construction to avoid repeated scans.
    let finalID: NodeID

    // MARK: - Testing-only bypass

    /// Constructs a `PipelineGraph` *without* running `validate()`.
    ///
    /// Only validator tests should call this: they need to feed the
    /// validator a deliberately malformed graph and observe the
    /// thrown error, which the designated initialiser's pre-check
    /// would otherwise intercept as an internal-invariant trap.
    ///
    /// Production lowering and optimiser code must use the
    /// `init(nodes:totalAdditionalInputs:)` designated initialiser,
    /// which validates on construction. This bypass is marked with
    /// a leading underscore to discourage misuse.
    internal init(
        _testInvalidNodes nodes: [Node],
        totalAdditionalInputs: Int
    ) {
        self.nodes = nodes
        self.totalAdditionalInputs = totalAdditionalInputs
        self.finalID = nodes.first(where: { $0.isFinal })?.id ?? -1
    }

    /// Designated initialiser. Runs `validate()` as a precondition.
    init(nodes: [Node], totalAdditionalInputs: Int) {
        self.nodes = nodes
        self.totalAdditionalInputs = totalAdditionalInputs

        // Precompute finalID by scanning once. If the graph is
        // invalid (no final / multiple finals), validate() will
        // trap and we fall back to the first node's id to keep
        // the struct well-formed in the Release-mode logged fault
        // path (see Invariant.check semantics).
        let finals = nodes.filter { $0.isFinal }
        if finals.count == 1 {
            self.finalID = finals[0].id
        } else {
            let fallback = nodes.first?.id ?? -1
            Invariant.check(
                false,
                "PipelineGraph must have exactly one isFinal node, got \(finals.count)"
            )
            self.finalID = fallback
        }

        do {
            try self.validate()
        } catch {
            Invariant.check(
                false,
                "PipelineGraph.init invariants violated: \(error)"
            )
        }
    }

    // MARK: - Validation

    /// Throws `PipelineError.filter(.invalidPassGraph)` if the graph
    /// violates any of the Phase-1 invariants documented in
    /// `docs/pipeline-compiler-design.md` §3.2:
    ///
    /// 1. Exactly one `isFinal == true` node.
    /// 2. Unique `id` per node.
    /// 3. Every `.node(id)` reference points to an earlier-declared
    ///    node.
    /// 4. Every `.additional(i)` reference is within
    ///    `totalAdditionalInputs`.
    /// 5. `outputSpec` is resolvable (Phase-1 check degenerates to
    ///    "not `.explicit(width: 0, height: 0)`" and "if
    ///    `.matching(passName:)`, the peer is declared earlier". Full
    ///    resolution against a source `TextureInfo` happens at
    ///    execution time in the allocator.)
    ///
    /// Thrown errors carry a short human-readable reason for the
    /// single violating Node's `debugLabel`, so a failing lowering
    /// run can quickly pinpoint the filter at fault.
    func validate() throws {
        // 1. Exactly one final node.
        let finalCount = nodes.reduce(0) { $0 + ($1.isFinal ? 1 : 0) }
        guard finalCount == 1 else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: "PipelineGraph",
                reason: "expected exactly one isFinal=true node, got \(finalCount)"
            ))
        }

        // 2. Unique ids.
        var seenIDs = Set<NodeID>()
        for node in nodes {
            if !seenIDs.insert(node.id).inserted {
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: "PipelineGraph",
                    reason: "duplicate node id \(node.id) (\(node.debugLabel))"
                ))
            }
        }

        // 3 & 4. Input references well-formed and topologically
        //        ordered.
        var declaredBefore = Set<NodeID>()
        for node in nodes {
            for ref in node.dependencyRefs {
                switch ref {
                case .source:
                    break   // always resolvable
                case .node(let referencedID):
                    if referencedID == node.id {
                        throw PipelineError.filter(.invalidPassGraph(
                            filterName: "PipelineGraph",
                            reason: "node \(node.id) (\(node.debugLabel)) references itself"
                        ))
                    }
                    guard declaredBefore.contains(referencedID) else {
                        throw PipelineError.filter(.invalidPassGraph(
                            filterName: "PipelineGraph",
                            reason: "node \(node.id) (\(node.debugLabel)) references \(referencedID) which is not declared earlier"
                        ))
                    }
                case .additional(let i):
                    guard i >= 0, i < totalAdditionalInputs else {
                        throw PipelineError.filter(.invalidPassGraph(
                            filterName: "PipelineGraph",
                            reason: "node \(node.id) (\(node.debugLabel)) references .additional(\(i)) but only \(totalAdditionalInputs) auxiliary inputs are declared"
                        ))
                    }
                }
            }
            declaredBefore.insert(node.id)
        }

        // 5. TextureSpec sanity. Full resolution happens at execution;
        //    at lowering time we just screen for structurally broken
        //    specs.
        for node in nodes {
            switch node.outputSpec {
            case .explicit(let w, let h):
                guard w > 0, h > 0 else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: "PipelineGraph",
                        reason: "node \(node.id) (\(node.debugLabel)) has non-positive explicit dimensions \(w)x\(h)"
                    ))
                }
            case .matching(let peer):
                // Peer must be a node name (debugLabel) declared
                // earlier. We rely on debugLabel uniqueness per graph.
                let earlierLabels = nodes
                    .prefix(while: { $0.id != node.id })
                    .map { $0.debugLabel }
                guard earlierLabels.contains(peer) else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: "PipelineGraph",
                        reason: "node \(node.id) (\(node.debugLabel)) has outputSpec .matching(\"\(peer)\") but no earlier node has that debugLabel"
                    ))
                }
            case .scaled(let factor):
                guard factor > 0 else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: "PipelineGraph",
                        reason: "node \(node.id) (\(node.debugLabel)) has non-positive scale factor \(factor)"
                    ))
                }
            case .matchShortSide(let target):
                guard target > 0 else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: "PipelineGraph",
                        reason: "node \(node.id) (\(node.debugLabel)) has non-positive matchShortSide \(target)"
                    ))
                }
            case .sameAsSource:
                break
            }
        }
    }

    // MARK: - Consumer-count analysis

    /// Number of distinct nodes that reference each node's output via
    /// `NodeRef.node(_)` in their `dependencyRefs`. Final nodes
    /// have zero consumers by graph invariant; orphaned non-final
    /// nodes (which DCE should have removed) also report zero.
    ///
    /// **Single source of truth** for fan-out reasoning. Every
    /// optimiser pass that decides "can I fuse / inline / sink this
    /// node?" must consult this map rather than rolling its own
    /// pass over `node.dependencyRefs` — keeping the consumer-count
    /// definition in one place means a future change to which fields
    /// participate in dependency tracking automatically propagates
    /// to every fan-out check.
    ///
    /// O(V + E). Re-compute, don't memoise — passes typically rebuild
    /// the graph between calls and the cost is negligible relative
    /// to the rest of optimisation.
    internal func consumerCounts() -> [NodeID: Int] {
        var counts: [NodeID: Int] = [:]
        for node in nodes {
            for ref in node.dependencyRefs {
                if case .node(let id) = ref {
                    counts[id, default: 0] += 1
                }
            }
        }
        return counts
    }

    // MARK: - Diagnostics

    /// Short debug dump: one line per node (`n{id} kind {label}`).
    /// Used by tests to assert graph shape without importing the
    /// whole struct.
    var dump: String {
        nodes.map { node in
            let final = node.isFinal ? " *final*" : ""
            return "n\(node.id) \(describe(kind: node.kind)) \(node.debugLabel)\(final)"
        }.joined(separator: "\n")
    }

    private func describe(kind: NodeKind) -> String {
        switch kind {
        case .pixelLocal(let body, _, let linear, _):
            return "pixelLocal(\(body.functionName), linear=\(linear))"
        case .neighborRead(let body, _, let r, _):
            return "neighborRead(\(body.functionName), r=\(r))"
        case .downsample(let f, let k):
            return "downsample(x\(f), \(k))"
        case .upsample(let f, let k):
            return "upsample(x\(f), \(k))"
        case .reduce(let op):
            return "reduce(\(op))"
        case .blend(let op, _):
            return "blend(\(op))"
        case .nativeCompute(let kernel, _, _):
            return "nativeCompute(\(kernel))"
        case .fusedPixelLocalCluster(let members, let linear, _):
            let names = members.map { $0.body.functionName }.joined(separator: "→")
            return "fusedCluster[\(names)], linear=\(linear)"
        }
    }
}
