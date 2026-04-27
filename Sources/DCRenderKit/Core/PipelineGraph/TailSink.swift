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

/// Absorb a downstream `.pixelLocal` into its producer's write
/// path.
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
/// 4. `M.outputSpec == P.outputSpec == .sameAsSource` — no
///    resolution change across the boundary.
/// 5. `M.kind` is one of `.fusedPixelLocalCluster` or
///    `.neighborRead`. `.pixelLocal` producers are already handled
///    by `VerticalFusion`; `.nativeCompute` producers are opaque
///    to the codegen and therefore skipped.
/// 6. `M.tailSinkedBody == nil` — no double-sinking yet.
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
/// ## Reference rewriting
///
/// After absorption, `M` (id preserved) produces what was P's
/// output — so any downstream node that referenced `P.id` must
/// have its reference rewritten to `M.id`. This is essential
/// when P is non-final and still has consumers (typical in
/// chains that mix single-pass pixel-local filters with multi-
/// pass filters whose internal passes reference earlier
/// intermediates via `NodeRef.node`). Without rewriting, dropping
/// P leaves dangling refs that `PipelineGraph.init`'s validator
/// rejects as "node X references Y which is not declared
/// earlier" with a fatal error.
///
/// P is dropped, and **every surviving node has its `inputs`,
/// per-kind `additionalNodeInputs` (or `aux` for `.blend`)
/// rewritten** to redirect any `NodeRef.node(P.id)` to
/// `NodeRef.node(M.id)`.
@available(iOS 18.0, *)
internal struct TailSink: OptimizerPass {

    let name = "TailSink"

    func run(_ graph: PipelineGraph) -> PipelineGraph {
        let byID: [NodeID: Node] = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
        )
        let consumerCount = graph.consumerCounts()

        var replacement: [NodeID: Node] = [:]
        var dropped: Set<NodeID> = []
        // refRewrite: P.id → M.id. After absorption, M produces what
        // was P's output, so every surviving node's `NodeRef.node(P)`
        // gets redirected to M.
        var refRewrite: [NodeID: NodeID] = [:]

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
                // M cannot be the pipeline's final output (final nodes
                // have zero consumers, which is already implied by the
                // `consumerCount == 1` guard above — this explicit check
                // is defensive symmetry with `KernelInlining`'s
                // `!pred.isFinal` line and surfaces intent to readers
                // skimming the fusion conditions).
                producer.isFinal == false,
                producer.outputSpec == .sameAsSource,
                producer.tailSinkedBody == nil
            else {
                continue
            }

            // Don't double-transform a producer we already
            // scheduled to sink another P into; nor a producer
            // that's itself an absorbed P.
            if replacement[producerID] != nil || dropped.contains(producerID) {
                continue
            }

            switch producer.kind {
            case .fusedPixelLocalCluster:
                guard
                    case let .fusedPixelLocalCluster(members, wantsLinear, clusterAux) = producer.kind
                else { continue }

                // Cluster codegen (`MetalSourceBuilder.buildFusedPixelLocalCluster`)
                // requires every member to use the `(rgb, u)` call form.
                // Absorbing a P with a non-fusable shape produced a mixed
                // cluster that codegen rejected with
                // `BuildError.unsupportedSignatureShape`, surfacing as a
                // hung preview + CPU spike (every frame retried the failing
                // build). LUT3DFilter (`.pixelLocalWithLUT3D`) was the
                // observed trigger. The fusable shape set is centralised in
                // `FusionBodySignatureShape.canFuseAsPixelLocalMember`.
                guard pBody.signatureShape.canFuseAsPixelLocalMember else {
                    continue
                }

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
                refRewrite[node.id] = producer.id

            case .neighborRead(let nBody, let nUniforms, let nRadius, let nAux):
                // Codegen for `.neighborRead` with tail-sunk body emits
                // `rgb = pBody(rgb, uTail);` between N's body call and
                // `output.write`. P's body needs the `(rgb, u)` call
                // form — same fusability gate as the cluster branch
                // above. Centralised in
                // `FusionBodySignatureShape.canFuseAsPixelLocalMember`.
                guard pBody.signatureShape.canFuseAsPixelLocalMember else {
                    continue
                }
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
                refRewrite[node.id] = producer.id

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

        // Build survivors, then rewrite every NodeRef.node(P) →
        // NodeRef.node(M) for any (P, M) in refRewrite. Applied
        // uniformly to both unchanged originals and replaced
        // (M+P) nodes — replaced nodes inherit M's `inputs`, which
        // may themselves point at a separately-absorbed P'.
        var survivors: [Node] = []
        survivors.reserveCapacity(graph.nodes.count)
        for node in graph.nodes {
            if dropped.contains(node.id) { continue }
            let raw = replacement[node.id] ?? node
            survivors.append(rewriteRefs(in: raw, using: refRewrite))
        }

        return PipelineGraph(
            nodes: survivors,
            totalAdditionalInputs: graph.totalAdditionalInputs
        )
    }

    // MARK: - Reference rewriting

    /// Replace every `NodeRef.node(id)` in `node` (across `inputs`
    /// and per-kind `additionalNodeInputs` / `aux`) where `id` is a
    /// key in `map`. `.source` and `.additional(_)` references pass
    /// through unchanged. Other ref-bearing fields on the surviving
    /// node (label, output spec, uniforms) are untouched.
    private func rewriteRefs(in node: Node, using map: [NodeID: NodeID]) -> Node {
        guard !map.isEmpty else { return node }

        let newInputs = node.inputs.map { rewriteRef($0, using: map) }
        let newKind: NodeKind

        switch node.kind {
        case let .pixelLocal(body, uniforms, linear, aux):
            newKind = .pixelLocal(
                body: body,
                uniforms: uniforms,
                wantsLinearInput: linear,
                additionalNodeInputs: aux.map { rewriteRef($0, using: map) }
            )
        case let .neighborRead(body, uniforms, radius, aux):
            newKind = .neighborRead(
                body: body,
                uniforms: uniforms,
                radiusHint: radius,
                additionalNodeInputs: aux.map { rewriteRef($0, using: map) }
            )
        case let .nativeCompute(name, uniforms, aux):
            newKind = .nativeCompute(
                kernelName: name,
                uniforms: uniforms,
                additionalNodeInputs: aux.map { rewriteRef($0, using: map) }
            )
        case let .fusedPixelLocalCluster(members, linear, aux):
            newKind = .fusedPixelLocalCluster(
                members: members,
                wantsLinearInput: linear,
                additionalNodeInputs: aux.map { rewriteRef($0, using: map) }
            )
        case let .blend(op, aux):
            newKind = .blend(op: op, aux: rewriteRef(aux, using: map))
        case .downsample, .upsample, .reduce:
            // No NodeRefs beyond `inputs` (already handled above).
            newKind = node.kind
        }

        // `withReplacedRefs` preserves `inlinedBodyBeforeSample` and
        // `tailSinkedBody` automatically — important here because
        // TailSink's input graph may already carry those markers from
        // earlier passes (KernelInlining), and the rewriter must not
        // strip them.
        return node.withReplacedRefs(kind: newKind, inputs: newInputs)
    }

    private func rewriteRef(_ ref: NodeRef, using map: [NodeID: NodeID]) -> NodeRef {
        if case .node(let id) = ref, let target = map[id] {
            return .node(target)
        }
        return ref
    }

}
