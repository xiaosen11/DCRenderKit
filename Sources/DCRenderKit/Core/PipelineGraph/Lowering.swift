//
//  Lowering.swift
//  DCRenderKit
//
//  Translates a consumer-facing `[AnyFilter]` chain into the internal
//  `PipelineGraph` IR. The lowering pass is deliberately mechanical —
//  it maps filters to nodes 1:1 for single-pass filters and maps
//  each `Pass` of a multi-pass filter to an individual node, without
//  attempting any fusion or simplification. Fusion happens in
//  Phase 2; codegen in Phase 3. See
//  `docs/pipeline-compiler-design.md` §3.2 for the invariants this
//  pass produces.
//

import Foundation

/// Phase-1 lowering pass. Pure function from `[AnyFilter]` to
/// `PipelineGraph?` — returns `nil` when the input describes no
/// work (empty chain, or a chain consisting entirely of multi-pass
/// filters that short-circuit to empty `passes`). Callers are
/// expected to treat `nil` as an identity pipeline and return the
/// source texture unchanged.
@available(iOS 18.0, *)
internal enum Lowering {

    /// Lower `steps` against a known source `TextureInfo`.
    ///
    /// The source info is required because some multi-pass filters
    /// (SoftGlow's adaptive pyramid, for example) decide their pass
    /// count from the input resolution. That makes lowering cheaper
    /// to re-run per-frame than to cache across varying source
    /// sizes; typical costs are on the order of a few microseconds
    /// for realistic chain lengths.
    ///
    /// - Parameters:
    ///   - steps: The consumer's filter chain. May be empty.
    ///   - source: Dimensions and pixel format of the pipeline's
    ///     resolved source texture. Multi-pass filters receive this
    ///     directly in `passes(input:)`; single-pass filters ignore
    ///     it at lowering time.
    /// - Returns: A validated `PipelineGraph` with exactly one
    ///   `isFinal = true` node, or `nil` if lowering produced no
    ///   work.
    static func lower(
        _ steps: [AnyFilter],
        source: TextureInfo
    ) -> PipelineGraph? {
        guard !steps.isEmpty else { return nil }

        // Pre-count additional inputs so we can translate local
        // `PassInput.additional(i)` / `FilterProtocol.additionalInputs[i]`
        // indices to the graph-global `.additional(i)` space.
        var totalAdditionalInputs = 0
        for step in steps {
            switch step {
            case .single(let f): totalAdditionalInputs += f.additionalInputs.count
            case .multi(let f):  totalAdditionalInputs += f.additionalInputs.count
            }
        }

        var nodes: [Node] = []
        var nextID: NodeID = 0
        var currentHead: NodeRef = .source
        var additionalOffset = 0
        let lastStepIndex = steps.count - 1

        for (stepIndex, step) in steps.enumerated() {
            let isLastStep = (stepIndex == lastStepIndex)

            switch step {
            case .single(let filter):
                guard let node = lowerSingleFilter(
                    filter,
                    id: nextID,
                    primaryInput: currentHead,
                    additionalOffset: additionalOffset,
                    stepIndex: stepIndex,
                    isPipelineFinal: isLastStep
                ) else {
                    // Structural failure — no modifier we can lower.
                    // Surface as "no graph" so the caller falls back
                    // to the source texture unchanged.
                    return nil
                }
                nodes.append(node)
                currentHead = .node(nextID)
                nextID += 1
                additionalOffset += filter.additionalInputs.count

            case .multi(let filter):
                let passes = filter.passes(input: source)
                if passes.isEmpty {
                    // Identity multi-pass (parameters zero, etc.).
                    // Chain head unchanged, no nodes emitted for
                    // this filter. The next step sees the previous
                    // filter's output as its input.
                    additionalOffset += filter.additionalInputs.count
                    continue
                }

                // Lower every Pass into a nativeCompute Node. Phase 2
                // may refine these into finer NodeKinds once the
                // optimiser recognises specific kernel-name patterns
                // (guided-downsample, bloom-bright, …).
                var passNameToID: [String: NodeID] = [:]
                var filterFinalID: NodeID?

                for pass in passes {
                    guard case .compute(let kernelName) = pass.modifier else {
                        // MultiPassExecutor already rejects non-
                        // compute passes at execution time; lowering
                        // mirrors the same constraint so invalid
                        // graphs never reach the optimiser.
                        return nil
                    }

                    let (primaryRef, additionalRefs) = translatePassInputs(
                        pass.inputs,
                        currentHead: currentHead,
                        passNameToID: passNameToID,
                        additionalOffset: additionalOffset
                    )
                    guard let primary = primaryRef else { return nil }

                    let node = Node(
                        id: nextID,
                        kind: .nativeCompute(
                            kernelName: kernelName,
                            uniforms: pass.uniforms,
                            additionalNodeInputs: additionalRefs
                        ),
                        inputs: [primary],
                        outputSpec: pass.output,
                        isFinal: false,   // pipeline-final assigned below
                        debugLabel: "\(type(of: filter))#\(stepIndex).\(pass.name)"
                    )
                    nodes.append(node)
                    passNameToID[pass.name] = nextID

                    if pass.isFinal {
                        filterFinalID = nextID
                    }
                    nextID += 1
                }

                guard let finalID = filterFinalID else {
                    // MultiPassFilter contract demands one
                    // `isFinal = true` pass; if the filter returned
                    // no final pass, lowering cannot proceed.
                    return nil
                }
                currentHead = .node(finalID)
                additionalOffset += filter.additionalInputs.count
            }
        }

        // No work produced (every multi-pass filter short-circuited)
        // ⇒ identity pipeline; caller handles.
        guard !nodes.isEmpty else { return nil }

        // Promote the final chain-head node to `isFinal = true`.
        // Graph-level invariant: exactly one node carries this flag,
        // enforced by `PipelineGraph.validate()` at construction.
        guard case .node(let lastID) = currentHead else {
            // currentHead must be .node(_) by now because we bailed
            // early on an empty nodes list above.
            return nil
        }
        if let idx = nodes.firstIndex(where: { $0.id == lastID }) {
            let old = nodes[idx]
            nodes[idx] = Node(
                id: old.id,
                kind: old.kind,
                inputs: old.inputs,
                outputSpec: old.outputSpec,
                isFinal: true,
                debugLabel: old.debugLabel
            )
        }

        return PipelineGraph(nodes: nodes, totalAdditionalInputs: totalAdditionalInputs)
    }

    // MARK: - Single-pass lowering

    /// Lower one `AnyFilter.single` occurrence. Returns `nil` only
    /// for genuinely unlowerable modifiers (non-compute single-pass
    /// filters, which DCR doesn't ship today but the pipeline tells
    /// us could exist via stickers / distortion in Phase 2+).
    private static func lowerSingleFilter(
        _ filter: any FilterProtocol,
        id: NodeID,
        primaryInput: NodeRef,
        additionalOffset: Int,
        stepIndex: Int,
        isPipelineFinal: Bool
    ) -> Node? {
        let label = "\(type(of: filter))#\(stepIndex)"
        let additionalRefs: [NodeRef] = (0..<filter.additionalInputs.count).map {
            .additional(additionalOffset + $0)
        }

        // Prefer the opt-in fusion body descriptor when the filter
        // adopts it; fall back to a `nativeCompute` node that
        // references the filter's standalone kernel by name.
        if let body = filter.fusionBody.body {
            let kind: NodeKind
            switch body.kind {
            case .pixelLocal:
                kind = .pixelLocal(
                    body: body,
                    uniforms: filter.uniforms,
                    wantsLinearInput: body.wantsLinearInput,
                    additionalNodeInputs: additionalRefs
                )
            case .neighborRead(let radius):
                kind = .neighborRead(
                    body: body,
                    uniforms: filter.uniforms,
                    radiusHint: radius,
                    additionalNodeInputs: additionalRefs
                )
            }
            return Node(
                id: id,
                kind: kind,
                inputs: [primaryInput],
                outputSpec: .sameAsSource,
                isFinal: isPipelineFinal,
                debugLabel: label
            )
        }

        // Unsupported fusion body ⇒ fall back to nativeCompute. Only
        // compute modifiers are lowerable in Phase 1.
        guard case .compute(let kernelName) = filter.modifier else {
            // Render / blit / MPS single-pass filters aren't modeled
            // by Phase 1's IR. Future phases may extend this.
            return nil
        }
        return Node(
            id: id,
            kind: .nativeCompute(
                kernelName: kernelName,
                uniforms: filter.uniforms,
                additionalNodeInputs: additionalRefs
            ),
            inputs: [primaryInput],
            outputSpec: .sameAsSource,
            isFinal: isPipelineFinal,
            debugLabel: label
        )
    }

    // MARK: - Multi-pass input translation

    /// Map a `[PassInput]` list (as declared by the filter) to a
    /// split (primaryInput, additionalInputs) pair in graph-global
    /// `NodeRef` space.
    ///
    /// - `PassInput.source`: the current chain head (filter-level
    ///   input), not the pipeline-level source — multi-pass filters
    ///   receive the previous chain step's output as their `.source`.
    /// - `PassInput.named(n)`: the node that was lowered from the
    ///   multi-pass filter's pass whose name is `n`. Forward
    ///   references are already prohibited by `MultiPassExecutor`'s
    ///   own validator, so missing names are impossible for
    ///   well-formed filters; we return `nil` in that case so
    ///   `lower(_:source:)` can surface the failure.
    /// - `PassInput.additional(i)`: translated to the graph-global
    ///   `.additional(i + additionalOffset)` slot.
    ///
    /// Returns `(nil, _)` only when a `.named` reference is
    /// unresolved — in practice a malformed filter.
    private static func translatePassInputs(
        _ inputs: [PassInput],
        currentHead: NodeRef,
        passNameToID: [String: NodeID],
        additionalOffset: Int
    ) -> (primary: NodeRef?, additional: [NodeRef]) {
        var refs: [NodeRef] = []
        for pi in inputs {
            switch pi {
            case .source:
                refs.append(currentHead)
            case .named(let n):
                guard let nodeID = passNameToID[n] else {
                    return (nil, [])
                }
                refs.append(.node(nodeID))
            case .additional(let i):
                refs.append(.additional(additionalOffset + i))
            }
        }
        guard let primary = refs.first else {
            return (nil, [])
        }
        return (primary, Array(refs.dropFirst()))
    }
}
