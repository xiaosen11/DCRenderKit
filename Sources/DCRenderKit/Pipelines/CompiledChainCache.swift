//
//  CompiledChainCache.swift
//  DCRenderKit
//
//  Per-`Pipeline` memoisation of the compiler's structural output.
//  `Lowering` is microsecond-cheap and runs every frame so we can
//  detect chain-topology changes; everything downstream of it is
//  expensive and uniform-value-independent, so we cache it.
//
//  Caching scope:
//    - `Optimizer.optimize(_:)` — five passes (DCE / VerticalFusion
//      / CSE / KernelInlining / TailSink), each O(N²) on graph
//      structure. ~hundreds of microseconds for a 16-filter chain.
//    - `Pipeline.computeChainInternalAlias(graph:)` — the
//      Phase 8 chain-internal walk used by the allocator.
//    - `TextureAliasingPlanner.plan(...)` — interval-graph
//      colouring, O(N × buckets).
//
//  Uniform values flow into nodes' `FilterUniforms` payloads.
//  Most optimiser passes are uniform-independent: DCE,
//  VerticalFusion, KernelInlining, and TailSink key only on node
//  kind, signature shape, `wantsLinearInput`, and consumer counts.
//  CSE is the exception — its `NodeSignature` equality includes
//  uniform bytes, so a rare uniform collision can fold two nodes
//  that would otherwise stand alone.
//
//  Either way, the cache fingerprint **must** include the raw
//  uniform bytes: cached entries store the optimised nodes with
//  their uniforms baked in, so a key that ignored uniforms would
//  return the previous frame's graph during a slider drag and
//  silently dispatch with stale slider values. Net effect: the
//  cache hits frame-after-frame on stable parameters (camera
//  preview, idle states) and correctly misses while a slider is
//  being dragged — re-running the optimiser each drag frame to
//  pick up the new uniforms.
//
//  The materialisation step (texture-pool dequeue) is *not* cached:
//  every frame still pulls fresh textures out of `TexturePool`
//  because the previous frame's textures may still be in flight on
//  the GPU. Caching the plan only saves the planner / optimiser
//  CPU work, not the texture allocations themselves (which the
//  pool already handles).
//

import Foundation
import Metal

/// Cache for the per-`Pipeline` compiler output.
///
/// One entry per Pipeline — the common runtime case is "filter
/// chain fixed at construction; preview source dimensions fixed
/// across frames." Both invariants make a single-slot cache
/// effectively a 100% hit rate after the first encode.
///
/// The cache key combines a structural fingerprint of the lowered
/// graph (node kinds, inputs, output specs, finality) with the
/// `(sourceInfo, optimization, intermediatePixelFormat)` triple
/// that drives the planner's bucket sizing. Any difference
/// invalidates the entry and forces a recompile.
@available(iOS 18.0, *)
internal final class CompiledChainCache: @unchecked Sendable {

    /// One memoised `(optimizedGraph, chainInternalAlias, plan)`
    /// triple keyed by the lowered-graph fingerprint plus the
    /// allocator-affecting environment.
    struct Entry {
        let loweredFingerprint: UInt64
        let sourceWidth: Int
        let sourceHeight: Int
        let sourcePixelFormat: MTLPixelFormat
        let intermediatePixelFormat: MTLPixelFormat
        let optimization: PipelineOptimization

        let optimizedGraph: PipelineGraph
        let chainInternalAlias: [NodeID: NodeID]
        let plan: TextureAliasingPlan
    }

    private let lock = NSLock()
    private var entry: Entry?

    /// Returns the cached entry if its key matches the supplied
    /// arguments, `nil` otherwise.
    func lookup(
        loweredFingerprint: UInt64,
        sourceInfo: TextureInfo,
        intermediatePixelFormat: MTLPixelFormat,
        optimization: PipelineOptimization
    ) -> Entry? {
        lock.lock()
        defer { lock.unlock() }

        guard let cached = entry,
              cached.loweredFingerprint == loweredFingerprint,
              cached.sourceWidth == sourceInfo.width,
              cached.sourceHeight == sourceInfo.height,
              cached.sourcePixelFormat == sourceInfo.pixelFormat,
              cached.intermediatePixelFormat == intermediatePixelFormat,
              cached.optimization == optimization
        else {
            return nil
        }
        return cached
    }

    /// Stores `entry`, replacing any previous entry. Single-slot:
    /// cache size is bounded at one because chain switches are
    /// rare events at user-facing UI layers.
    func store(_ newEntry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        entry = newEntry
    }

    /// Drop the cached entry. Used by tests; production code
    /// invalidates implicitly on key mismatch.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }
}

// MARK: - Lowered-graph fingerprint

@available(iOS 18.0, *)
extension CompiledChainCache {

    /// Compute a fingerprint of `graph` covering both topology AND
    /// the uniform-byte payloads of every node that carries them.
    ///
    /// The fingerprint hashes:
    ///   - node count + final-node ID + total additional inputs
    ///   - per node: id, kind discriminator + structural payload,
    ///     **uniform bytes**, primary inputs, output spec, `isFinal`
    ///
    /// **Why uniform bytes participate**: the cached `optimizedGraph`
    /// stores nodes with their uniforms baked in. If two encodes
    /// share topology but differ in uniform values (slider drag),
    /// excluding uniforms from the key would return a stale graph
    /// with old uniforms — the symptom is "slider doesn't change
    /// the rendering." The fingerprint must invalidate on any
    /// uniform delta to keep the cached graph in sync with current
    /// state.
    ///
    /// **Hit rate consequence**: camera preview (uniforms stable
    /// per frame) hits the cache every frame after the first.
    /// Slider drag misses on every frame during the drag (each frame
    /// re-runs the optimiser). Both behaviours are the right ones.
    static func fingerprint(of graph: PipelineGraph) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(graph.nodes.count)
        hasher.combine(graph.totalAdditionalInputs)
        hasher.combine(graph.finalID)
        for node in graph.nodes {
            hasher.combine(node.id)
            hasher.combine(node.isFinal)
            hasher.combine(node.inputs)
            hashOutputSpec(node.outputSpec, into: &hasher)
            hashKind(node.kind, into: &hasher)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Materialise a `FilterUniforms` payload into raw bytes for
    /// fingerprint inclusion. Mirrors `NodeSignature.uniformBytesOf`
    /// but lives here so the cache layer doesn't depend on the
    /// signature's private helper.
    private static func uniformBytes(_ uniforms: FilterUniforms) -> [UInt8] {
        guard uniforms.byteCount > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: uniforms.byteCount) { buffer, count in
            uniforms.copyBytes(buffer.baseAddress!)
            count = uniforms.byteCount
        }
    }

    private static func hashOutputSpec(_ spec: TextureSpec, into hasher: inout Hasher) {
        switch spec {
        case .sameAsSource:
            hasher.combine(0)
        case let .scaled(factor):
            hasher.combine(1)
            hasher.combine(factor)
        case let .explicit(w, h):
            hasher.combine(2)
            hasher.combine(w)
            hasher.combine(h)
        case let .matchShortSide(s):
            hasher.combine(3)
            hasher.combine(s)
        case let .matching(passName):
            hasher.combine(4)
            hasher.combine(passName)
        }
    }

    private static func hashKind(_ kind: NodeKind, into hasher: inout Hasher) {
        switch kind {
        case let .pixelLocal(body, uniforms, linear, aux):
            hasher.combine(0)
            hasher.combine(body.functionName)
            // Including signatureShape in the key is defensive: the SDK
            // ships unique functionNames per filter today so the shape
            // discriminator is redundant, but mixing it in costs one
            // hash combine and protects the cache key against a future
            // user-registered filter that happens to reuse a built-in
            // body name with a different shape.
            hasher.combine(body.signatureShape)
            hasher.combine(uniformBytes(uniforms))
            hasher.combine(linear)
            hasher.combine(aux)
        case let .neighborRead(body, uniforms, radius, aux):
            hasher.combine(1)
            hasher.combine(body.functionName)
            hasher.combine(body.signatureShape)
            hasher.combine(uniformBytes(uniforms))
            hasher.combine(radius)
            hasher.combine(aux)
        case let .downsample(factor, dKind):
            hasher.combine(2)
            hasher.combine(factor)
            hasher.combine(dKind)
        case let .upsample(factor, uKind):
            hasher.combine(3)
            hasher.combine(factor)
            hasher.combine(uKind)
        case let .reduce(op):
            hasher.combine(4)
            hasher.combine(op)
        case let .blend(op, aux):
            hasher.combine(5)
            hasher.combine(op)
            hasher.combine(aux)
        case let .nativeCompute(kernelName, uniforms, aux):
            hasher.combine(6)
            hasher.combine(kernelName)
            hasher.combine(uniformBytes(uniforms))
            hasher.combine(aux)
        case let .fusedPixelLocalCluster(members, linear, aux):
            // Lowering never produces this directly — clusters
            // appear only in the optimised graph. Hashing it is
            // defensive in case a future caller fingerprints an
            // already-optimised graph.
            hasher.combine(7)
            hasher.combine(linear)
            hasher.combine(aux)
            for member in members {
                hasher.combine(member.body.functionName)
                hasher.combine(uniformBytes(member.uniforms))
            }
        }
    }
}
