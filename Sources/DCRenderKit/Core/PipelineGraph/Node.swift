//
//  Node.swift
//  DCRenderKit
//
//  Internal IR for the pipeline compiler. A `Node` represents one unit
//  of GPU work — either a per-pixel body, a neighbourhood read, a
//  scale change, a reduction, a blend, or an opaque compute kernel
//  (the Phase-1 fallback for Metal kernels the compiler doesn't yet
//  model explicitly). Lowering (`PipelineGraph.lowering`) translates
//  `[AnyFilter]` into an ordered list of `Node` values; optimisation
//  passes (Phase 2) rewrite the list; backend codegen (Phase 3/7)
//  consumes it.
//
//  Everything in this file is `internal`. The design decision to keep
//  the IR out of the public surface is documented in
//  `docs/pipeline-compiler-design.md` §1.2 and §9.
//

import Foundation
import Metal

// MARK: - NodeID

/// Stable identifier for a `Node` within one `PipelineGraph`. IDs are
/// assigned in declaration order by the lowering pass; optimiser
/// passes never reuse a retired ID. Using a plain `Int` keeps diagnostics
/// easy to read (graph dumps print `n0 → n1 → n2 …`).
internal typealias NodeID = Int

// MARK: - NodeRef

/// Reference to an input texture consumed by a `Node`. Exactly one
/// variant is used per slot.
///
/// - `source` is the pipeline's resolved input texture (the chain's
///   starting point).
/// - `node` references another `Node` in the same graph and requires
///   that referenced node to appear earlier in the declaration order
///   (validated by `PipelineGraph.validate`).
/// - `additional` indexes into the filter-level `additionalInputs`
///   array — typically a mask, overlay, or LUT that a
///   `MultiPassFilter` made available to every pass.
internal enum NodeRef: Sendable, Hashable {
    case source
    case node(NodeID)
    case additional(Int)
}

// MARK: - Auxiliary enums

/// How a downsample Node reduces resolution. Tagged because later
/// optimiser passes treat these differently — e.g. CSE only merges
/// two downsamples if their `kind` (sampling strategy) matches.
internal enum DownsampleKind: Sendable, Hashable {
    /// Guided-filter specific: emits `(luma, luma²)` pair at 1/4 res.
    case guidedLuma
    /// Simple box average for pyramid bases (SoftGlow, etc.).
    case boxAvg
    /// MPS-backed reduction wrapping an MPS kernel. The specific
    /// MPS kernel is identified by the attached `kernelName` on the
    /// owning Node's `NativeCompute` variant when needed.
    case mpsMean
}

/// How an upsample Node raises resolution. Same tagging rationale as
/// `DownsampleKind`.
internal enum UpsampleKind: Sendable, Hashable {
    case bilinear
    case nearest
}

/// Full-image reduction operations. Extend as new reductions arrive
/// (variance, histogram, …) — every one creates a single pixel of
/// output so they don't participate in vertical fusion.
internal enum ReduceOp: Sendable, Hashable {
    case lumaMean
}

/// Two-source blend operations. The `aux` reference lives on the Node
/// wrapping this op rather than inside the enum so lifetime analysis
/// can treat it uniformly with primary inputs.
internal enum BlendOp: Sendable, Hashable {
    case normalAlpha
    case screen
    case softLight
}

// MARK: - NodeKind

/// Body-function metadata captured at lowering time so the optimiser
/// and codegen phases don't have to re-walk the originating filter.
///
/// Each variant is chosen so its invariants are checkable by the
/// optimiser *without* consulting the filter (e.g. "can I vertical-
/// fuse these two?" reduces to "are both `.pixelLocal` with matching
/// `wantsLinearInput` and no fan-out?").
internal enum NodeKind: Sendable {

    /// Per-pixel function. Its body reads only the pixel at the
    /// thread's own grid coordinate (on the primary source and on
    /// any auxiliary inputs the filter declared, such as LUT3D's
    /// lookup texture or NormalBlend's overlay). Candidate for
    /// vertical fusion with any adjacent `.pixelLocal` whose
    /// `wantsLinearInput` matches (Phase 2).
    ///
    /// `additionalNodeInputs` carries references to non-primary
    /// texture inputs — LUT, overlay, mask — that the body reads at
    /// the same coordinate as the source. The allocator (Phase 4)
    /// resolves these to concrete textures via the graph's
    /// `totalAdditionalInputs` contract.
    case pixelLocal(
        body: FusionBody,
        uniforms: FilterUniforms,
        wantsLinearInput: Bool,
        additionalNodeInputs: [NodeRef]
    )

    /// Neighbourhood read function. Its body samples `radiusHint`
    /// pixels in each axis around the thread's grid coordinate.
    /// `additionalNodeInputs` carries references to texture inputs
    /// beyond the primary source (overlay, mask, …) — these are
    /// resolved to concrete textures by the scheduler.
    case neighborRead(
        body: FusionBody,
        uniforms: FilterUniforms,
        radiusHint: Int,
        additionalNodeInputs: [NodeRef]
    )

    /// Resolution-reducing operation. Rendered by the appropriate
    /// MPS / compute backend; never participates in vertical fusion
    /// (output dimensions differ from inputs).
    case downsample(factor: Float, kind: DownsampleKind)

    /// Resolution-increasing operation. Same fusion constraints as
    /// `.downsample`.
    case upsample(factor: Float, kind: UpsampleKind)

    /// Full-image reduction producing a single pixel of output.
    case reduce(op: ReduceOp)

    /// Two-source composite. The `aux` second input is carried here
    /// rather than on the enclosing Node so lowering can identify a
    /// blend without inspecting `inputs.count`.
    case blend(op: BlendOp, aux: NodeRef)

    /// Phase-1 catch-all: an opaque compute kernel whose semantics
    /// the compiler does not yet model. Used for:
    ///
    /// - `FilterProtocol` conformers whose `fusionBody` is
    ///   `.unsupported` (third-party filters shipping their own
    ///   kernel via `ShaderLibrary.register`).
    /// - `MultiPassFilter.passes` results whose `modifier` kernel
    ///   name doesn't match a known Node semantic (e.g.
    ///   `DCRGuidedComputeAB`, Poisson-blur passes). Later phases
    ///   progressively refine these into finer-grained NodeKinds
    ///   as fusion opportunities justify the modeling effort.
    ///
    /// `NativeCompute` never participates in vertical fusion; it
    /// dispatches exactly the kernel named by `kernelName` on its
    /// own.
    case nativeCompute(
        kernelName: String,
        uniforms: FilterUniforms,
        additionalNodeInputs: [NodeRef]
    )
}

// MARK: - Node

/// One unit of work in the pipeline graph. Immutable; rewrites
/// produce new `Node` values rather than mutating in place, matching
/// the pure-function style of the optimiser passes.
internal struct Node: Sendable, Identifiable {

    /// Stable graph-scoped identifier. Assigned by lowering in
    /// declaration order; never reused.
    let id: NodeID

    /// What this node computes.
    let kind: NodeKind

    /// Ordered texture inputs. Index 0 is the primary source for
    /// `.pixelLocal` / `.neighborRead` / `.downsample` / `.upsample`
    /// / `.reduce`; `.blend` uses index 0 as the destination-side
    /// input and `.blend(aux:)` separately carries the auxiliary.
    ///
    /// Inputs are references to prior nodes, the pipeline source, or
    /// filter-level additional inputs. Phase-1 validation ensures
    /// every `.node(id)` refers to a node declared before this one.
    let inputs: [NodeRef]

    /// Spec for the output texture this node writes. Reuses the
    /// existing `TextureSpec` enum so the allocator (Phase 4) can
    /// resolve it against the source texture's actual dimensions.
    let outputSpec: TextureSpec

    /// Whether this node's output is the pipeline's final result.
    /// Exactly one node per graph has this set — enforced by
    /// `PipelineGraph.validate`.
    let isFinal: Bool

    /// Human-readable label used in diagnostic logs and graph dumps.
    /// Typically `"Exposure#3"` (filter name + index in chain).
    let debugLabel: String
}

// MARK: - Node dependency traversal

extension Node {

    /// Every `NodeRef` this node consumes — primary `inputs` plus
    /// any kind-specific auxiliary references (pixelLocal
    /// `additionalNodeInputs`, neighborRead `additionalNodeInputs`,
    /// nativeCompute `additionalNodeInputs`, blend `aux`).
    ///
    /// Used by the `PipelineGraph` validator (forward-reference
    /// check) and by every optimiser pass (reachability for DCE,
    /// fan-out tests for VerticalFusion / KernelInlining, etc.).
    /// Return order matches input order so diagnostics see deps in
    /// the order the shader sees them.
    internal var dependencyRefs: [NodeRef] {
        var refs = inputs
        switch kind {
        case .pixelLocal(_, _, _, let additional):
            refs.append(contentsOf: additional)
        case .neighborRead(_, _, _, let additional):
            refs.append(contentsOf: additional)
        case .nativeCompute(_, _, let additional):
            refs.append(contentsOf: additional)
        case .blend(_, let aux):
            refs.append(aux)
        case .downsample, .upsample, .reduce:
            break
        }
        return refs
    }
}
