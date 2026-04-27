//
//  TextureAliasingPlanner.swift
//  DCRenderKit
//
//  Phase 4 core algorithm. Analyses a `PipelineGraph` and
//  determines which nodes can share physical textures — two
//  outputs with matching dimensions/format whose lifetimes don't
//  overlap are alias-eligible, so the downstream allocator only
//  needs one `MTLTexture` per bucket instead of one per node.
//
//  The planner is pure: no Metal, no I/O, no global state. It
//  operates on the graph's structural properties (node order,
//  dependency refs, output specs) and a source `TextureInfo` for
//  resolving `.sameAsSource` / `.scaled` / `.matchShortSide`
//  outputs. Testing the aliasing decisions therefore runs without
//  a GPU — the Phase-5 wiring layer handles the real
//  `MTLTexture` dispensation via `LifetimeAwareTextureAllocator`.
//

import Foundation

/// Result of the aliasing planner — a map from NodeID to bucket
/// index, plus the canonical `TextureInfo` each bucket represents.
///
/// Two nodes with the same bucket index will share a physical
/// texture at allocation time. Buckets are contiguous 0-indexed
/// integers; `uniqueBucketCount` is the total bucket count (the
/// peak simultaneous-texture count the graph will hold).
@available(iOS 18.0, *)
internal struct TextureAliasingPlan: Sendable {

    /// Bucket index assigned to each node's output. Missing entry
    /// means the node's output was never allocated (unreachable
    /// node — should have been DCE'd, but the planner doesn't
    /// trust that and silently skips).
    let bucketOf: [NodeID: Int]

    /// Resolved texture spec for each bucket. Nodes that share a
    /// bucket all produce outputs of this spec by construction.
    let bucketSpec: [Int: TextureInfo]

    /// Number of distinct buckets in the plan. Equals the peak
    /// texture count the allocator will dispense.
    var uniqueBucketCount: Int { bucketSpec.count }
}

/// Pure aliasing planner. Walks the graph in declaration order,
/// analysing each node's lifetime and picking the earliest-
/// released compatible bucket.
///
/// ## Algorithm
///
/// 1. Build a `consumers[nodeID]` map — for every node N, the list
///    of nodes that reference `.node(N.id)` via `dependencyRefs`.
///    The max consumer id is N's "end-of-life" step.
/// 2. Final nodes receive `Int.max` as their end-of-life, so their
///    bucket never returns to the reuse pool. This protects the
///    pipeline's final output from being overwritten by a later
///    intermediate dispatch while the caller still holds it.
/// 3. Walk nodes in declaration order. At each node:
///    a. Release any bucket whose end-of-life was **strictly less
///       than** the current node's id (strict inequality because
///       a consumer uses its inputs at its own step, so the input
///       bucket can only be reused at `consumer.id + 1` — or
///       equivalently, at step `consumer.id + 1` and beyond).
///    b. Resolve the node's output spec to a concrete `TextureInfo`.
///    c. Try to reuse an available bucket whose spec matches.
///    d. Otherwise allocate a fresh bucket.
///    e. Record this node's assignment and its end-of-life.
///
/// Greedy by release time achieves the classic graph-colouring
/// bound: if the graph's interval overlap is K-colourable,
/// greedy produces K buckets. For the DCR pipeline graph every
/// node's lifetime is a contiguous interval on the 1-D timeline
/// (declaration order), so interval graph colouring is optimal —
/// the planner hits the theoretical minimum.
@available(iOS 18.0, *)
internal enum TextureAliasingPlanner {

    /// Build an aliasing plan for `graph`. The `sourceInfo` feeds
    /// `TextureSpec.resolve(source:resolvedPeers:)` so relative
    /// output specs (`.scaled(factor:)`, `.matchShortSide(_:)`)
    /// land on concrete dimensions.
    ///
    /// `chainInternalAlias` describes nodes whose physical output
    /// is tile-memory only — i.e. clusters in the middle of a
    /// `RenderBackend.executeChain` draw chain that pass their
    /// result to the next cluster via programmable blending and
    /// never write a texture. The planner skips bucket allocation
    /// for them and aliases their `bucketOf` entry to the chain
    /// tail's bucket so `mapping[id]` lookups still resolve.
    /// Pass `[:]` when no chain collapsing applies.
    static func plan(
        graph: PipelineGraph,
        sourceInfo: TextureInfo,
        chainInternalAlias: [NodeID: NodeID] = [:]
    ) -> TextureAliasingPlan {
        guard !graph.nodes.isEmpty else {
            return TextureAliasingPlan(bucketOf: [:], bucketSpec: [:])
        }

        // Step 1: consumer analysis → end-of-life per node.
        let endOfLife = computeEndOfLife(graph: graph)

        // Step 2: allocate buckets by walking declaration order.
        var bucketOf: [NodeID: Int] = [:]
        var bucketSpec: [Int: TextureInfo] = [:]
        var bucketEnd: [Int: Int] = [:]         // bucket → end-of-life (for release check)
        var freePerSpec: [TextureInfo: [Int]] = [:]   // spec → released bucket indices (LIFO)
        var nextBucketIndex = 0

        // We also need resolvedPeers for `.matching(passName:)`
        // specs — same pattern `MultiPassExecutor.execute` uses.
        var resolvedInfos: [String: TextureInfo] = [:]

        for node in graph.nodes {
            // 2a. Release any bucket whose owner's end-of-life was
            //     strictly before the current node's id. Such a
            //     bucket is safe to reuse for the current node (it
            //     will NOT be read at this step because its last
            //     consumer already ran).
            //
            // Snapshot the buckets to release first, then mutate
            // `bucketEnd`. Iterating a `Dictionary` while removing
            // entries from it is undefined behaviour in Swift even
            // though the iterator may appear to work for small
            // dictionaries — it can crash or skip entries on rehash.
            let toRelease = bucketEnd.compactMap { (bucket, end) -> Int? in
                end < node.id ? bucket : nil
            }
            for bucket in toRelease {
                if let spec = bucketSpec[bucket] {
                    freePerSpec[spec, default: []].append(bucket)
                }
                bucketEnd.removeValue(forKey: bucket)
            }

            // 2b. Skip allocation for chain-internal clusters —
            //     their output never reaches a real texture.
            if chainInternalAlias[node.id] != nil {
                continue
            }

            // 2c. Resolve this node's output spec.
            guard let spec = node.outputSpec.resolve(
                source: sourceInfo,
                resolvedPeers: resolvedInfos
            ) else {
                // Invalid spec — skip this node. The graph's
                // `validate()` pass should have rejected it; if it
                // reached here anyway the planner stays well-
                // behaved (the allocator layer surfaces the
                // structural error).
                continue
            }
            resolvedInfos[node.debugLabel] = spec

            // 2d. Try to reuse a bucket from the free list.
            let assignedBucket: Int
            if var freeBuckets = freePerSpec[spec], !freeBuckets.isEmpty {
                assignedBucket = freeBuckets.removeLast()
                freePerSpec[spec] = freeBuckets.isEmpty ? nil : freeBuckets
            } else {
                // 2e. Allocate fresh.
                assignedBucket = nextBucketIndex
                nextBucketIndex += 1
                bucketSpec[assignedBucket] = spec
            }

            // 2f. Record assignment and its end-of-life.
            bucketOf[node.id] = assignedBucket
            bucketEnd[assignedBucket] = endOfLife[node.id] ?? node.id
        }

        // Step 3: alias chain-internal IDs to their chain tail's
        // bucket so `mapping[chainInternalID]` resolves to the
        // tail texture (harmless — the dispatch path never reads
        // it as input or writes to it as output).
        for (internalID, tailID) in chainInternalAlias {
            if let tailBucket = bucketOf[tailID] {
                bucketOf[internalID] = tailBucket
            }
        }

        return TextureAliasingPlan(
            bucketOf: bucketOf,
            bucketSpec: bucketSpec
        )
    }

    // MARK: - Private: lifetime analysis

    /// Compute the end-of-life step for every node. Final nodes
    /// get `Int.max` so their bucket never returns to the free
    /// list — protects the pipeline's output from being aliased
    /// by an earlier dispatch while the caller still holds it.
    ///
    /// Nodes without consumers (non-final orphans, which DCE
    /// should have removed) get their own id as end-of-life so
    /// their bucket is released immediately after allocation.
    /// That keeps the planner robust if DCE was skipped.
    private static func computeEndOfLife(
        graph: PipelineGraph
    ) -> [NodeID: Int] {
        var consumers: [NodeID: Int] = [:]
        for node in graph.nodes {
            for ref in node.dependencyRefs {
                if case .node(let depID) = ref {
                    consumers[depID] = max(consumers[depID] ?? -1, node.id)
                }
            }
        }

        var endOfLife: [NodeID: Int] = [:]
        for node in graph.nodes {
            if node.isFinal {
                endOfLife[node.id] = .max
            } else {
                // Consumer exists → its id is the end-of-life.
                // No consumer → own id (bucket released immediately).
                endOfLife[node.id] = consumers[node.id] ?? node.id
            }
        }
        return endOfLife
    }
}

// MARK: - TextureInfo Hashable

// `TextureInfo` is already `Hashable` in the existing public API
// (`Core/MultiPassFilter.swift`), so we don't need to synthesise it
// here — its properties are width / height / pixelFormat which all
// Hash trivially. If that contract ever changes the planner's
// `freePerSpec` dictionary would need its own composite key; the
// Phase-4 tests pin the current dependency.
