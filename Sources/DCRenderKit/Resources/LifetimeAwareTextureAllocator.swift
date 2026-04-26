//
//  LifetimeAwareTextureAllocator.swift
//  DCRenderKit
//
//  Phase 4 concrete allocator. Combines `TextureAliasingPlanner`'s
//  bucket plan with `TexturePool` to dispense one `MTLTexture` per
//  bucket — and therefore one per set of nodes whose lifetimes
//  don't overlap.
//
//  Typical flow inside `Pipeline.encode` (Phase 5):
//
//    1. Lower + optimise the filter chain → `PipelineGraph`.
//    2. Call `allocator.allocate(graph:, sourceInfo:)` → returns
//       `[NodeID: MTLTexture]` mapping (multiple IDs may share
//       the same MTLTexture).
//    3. Dispatch each node using the mapped texture as destination
//       and the upstream node's mapped texture as primary input.
//    4. After the command buffer completes, call
//       `allocator.release(plan:)` to return every non-final
//       bucket to the pool.
//
//  Correctness relies on the planner's guarantee that aliased
//  nodes have strictly disjoint lifetimes — once a node's
//  end-of-life step finishes encoding, the bucket is safe to
//  reuse for a later node at the same spec.
//

import Foundation
import Metal

/// Concrete `MTLTexture` dispenser driven by the aliasing plan.
///
/// Not a singleton — callers construct their own instance to bind
/// the allocator to a specific `TexturePool`. The shared path
/// (`.shared`) uses `TexturePool.shared`; tests typically build
/// their own for isolation.
@available(iOS 18.0, *)
internal final class LifetimeAwareTextureAllocator: @unchecked Sendable {

    /// Singleton bound to `TexturePool.shared`. Production code
    /// goes through this; tests can build their own with a
    /// different pool.
    static let shared = LifetimeAwareTextureAllocator(pool: .shared)

    private let pool: TexturePool

    init(pool: TexturePool) {
        self.pool = pool
    }

    /// Materialise the aliasing plan. Returns a map from NodeID
    /// to the `MTLTexture` that node should write into. Sibling
    /// nodes with the same bucket index in the plan share one
    /// `MTLTexture`; dispatching them in declaration order is
    /// safe because the planner guarantees disjoint lifetimes.
    ///
    /// - Parameters:
    ///   - graph: The lowered + optimised pipeline graph.
    ///   - sourceInfo: Dimensions / format of the pipeline's
    ///     source texture. Used to resolve relative output specs
    ///     (`.scaled(factor:)` etc).
    /// - Returns: `(mapping, plan)` — `mapping` is the
    ///   NodeID-to-texture dictionary callers dispatch against;
    ///   `plan` is the underlying bucket plan, passed to
    ///   `release(plan:)` when the command buffer completes.
    /// - Throws: `PipelineError.texture(.textureCreationFailed)`
    ///   when the pool can't allocate — same contract as the
    ///   existing `TexturePool.dequeue`.
    /// `@unchecked Sendable` because `MTLTexture` (an Apple
    /// protocol) isn't itself `Sendable` in Swift 6, but the
    /// `Allocation` value is constructed, read, and consumed
    /// within a single call to `Pipeline.encode` (always on the
    /// thread that called it) — the mapping is never shared
    /// across actors. The underlying `TexturePool` is
    /// thread-safe separately via its own NSLock.
    struct Allocation: @unchecked Sendable {
        let mapping: [NodeID: MTLTexture]
        let plan: TextureAliasingPlan

        /// Unique textures (one per bucket) that must be released
        /// after the command buffer completes. Excludes the
        /// final-node's texture — that one is handed to the
        /// caller.
        internal let intermediateTextures: [MTLTexture]
    }

    func allocate(
        graph: PipelineGraph,
        sourceInfo: TextureInfo
    ) throws -> Allocation {
        let plan = TextureAliasingPlanner.plan(
            graph: graph,
            sourceInfo: sourceInfo
        )

        // Materialise one MTLTexture per bucket. Buckets are
        // 0-indexed contiguous integers by construction.
        var bucketTextures: [Int: MTLTexture] = [:]
        for (bucket, info) in plan.bucketSpec {
            // `.renderTarget` is added alongside the compute-path
            // usages so a single bucket can back either a compute
            // dispatch (shader read/write) or a Phase-8 render-chain
            // dispatch (colour attachment) without being
            // re-allocated. The flag is free on Apple Silicon TBDR
            // GPUs and lets `RenderBackend.execute*` succeed without
            // requiring the pool to maintain two parallel
            // (renderTarget vs shader-only) variants.
            let texture = try pool.dequeue(spec: TexturePoolSpec(
                width: info.width,
                height: info.height,
                pixelFormat: info.pixelFormat,
                usage: [.shaderRead, .shaderWrite, .renderTarget],
                storageMode: .private
            ))
            bucketTextures[bucket] = texture
        }

        // Build the per-node mapping. Nodes sharing a bucket
        // receive the same `MTLTexture` reference.
        var mapping: [NodeID: MTLTexture] = [:]
        for (nodeID, bucket) in plan.bucketOf {
            guard let texture = bucketTextures[bucket] else {
                // Planner and the bucketSpec dictionary should
                // always be consistent; surface invariant
                // violation as a clear error rather than a
                // fatalError.
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: "LifetimeAwareTextureAllocator",
                    reason: "bucket \(bucket) missing materialised texture for node \(nodeID)"
                ))
            }
            mapping[nodeID] = texture
        }

        // Collect textures that aren't the final node's. Those
        // go back to the pool after the CB completes.
        let finalBucket = plan.bucketOf[graph.finalID]
        let intermediateTextures = bucketTextures
            .filter { $0.key != finalBucket }
            .map { $0.value }

        return Allocation(
            mapping: mapping,
            plan: plan,
            intermediateTextures: intermediateTextures
        )
    }

    /// Return every non-final intermediate texture to the pool.
    /// Callers route this through
    /// `scheduleDeferredEnqueue(textures:pool:commandBuffer:)` so
    /// the actual enqueue happens on the command buffer's
    /// completion handler — the cross-CB race rationale that
    /// `Pipeline.swift`'s existing infrastructure already covers.
    func scheduleRelease(
        _ allocation: Allocation,
        commandBuffer: MTLCommandBuffer
    ) {
        scheduleDeferredEnqueue(
            textures: allocation.intermediateTextures,
            pool: pool,
            commandBuffer: commandBuffer
        )
    }
}
