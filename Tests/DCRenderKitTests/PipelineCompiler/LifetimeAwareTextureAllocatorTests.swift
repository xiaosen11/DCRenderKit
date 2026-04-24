//
//  LifetimeAwareTextureAllocatorTests.swift
//  DCRenderKitTests
//
//  Integration tests for the Phase-4 concrete allocator. These
//  use a real `TexturePool` but the pool sits on `Device.shared`
//  so they need Metal; planner-level tests stay hermetic in a
//  separate file.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class LifetimeAwareTextureAllocatorTests: XCTestCase {

    private typealias Fx = PipelineCompilerTestFixtures

    private var pool: TexturePool!
    private var allocator: LifetimeAwareTextureAllocator!

    override func setUpWithError() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }
        // Use an isolated pool per test so cache state doesn't
        // leak across runs.
        pool = TexturePool(device: .shared)
        allocator = LifetimeAwareTextureAllocator(pool: pool)
    }

    private var sourceInfo: TextureInfo {
        TextureInfo(width: 128, height: 128, pixelFormat: .rgba16Float)
    }

    // MARK: - Basic allocation

    /// Allocating for a 3-node ping-pong chain produces a
    /// mapping where nodes 0 and 2 share a texture, node 1 has
    /// its own. Two unique `MTLTexture` references materialise
    /// — the planner's bucket-count claim is exercised on the
    /// real MTLTexture layer.
    func testThreeNodeChainShareTwoTextures() throws {
        let graph = Fx.linearPixelLocalChain(length: 3)
        let allocation = try allocator.allocate(graph: graph, sourceInfo: sourceInfo)

        XCTAssertEqual(allocation.plan.uniqueBucketCount, 2)

        // ObjectIdentifier-based set: same texture instance must
        // appear as the same pointer.
        let distinctTextures = Set(allocation.mapping.values.map { ObjectIdentifier($0) })
        XCTAssertEqual(distinctTextures.count, 2)

        // Nodes 0 and 2 resolve to identical texture pointer.
        XCTAssertIdentical(
            allocation.mapping[0] as AnyObject,
            allocation.mapping[2] as AnyObject,
            "Nodes 0 and 2 must share a physical texture"
        )
        // Nodes 0 and 1 must NOT share.
        XCTAssertNotIdentical(
            allocation.mapping[0] as AnyObject,
            allocation.mapping[1] as AnyObject,
            "Nodes 0 and 1 have overlapping lifetimes — must not share"
        )
    }

    // MARK: - Per-node texture spec

    /// Every allocated texture must match the requested pixel
    /// format and dimensions. This catches a Phase-4 regression
    /// where the planner returns the right spec but the allocator
    /// passes the wrong one to `TexturePool.dequeue`.
    func testEveryAllocatedTextureHasExpectedSpec() throws {
        let graph = Fx.linearPixelLocalChain(length: 4)
        let allocation = try allocator.allocate(graph: graph, sourceInfo: sourceInfo)

        for (nodeID, texture) in allocation.mapping {
            XCTAssertEqual(texture.width, sourceInfo.width,
                           "Node \(nodeID): width")
            XCTAssertEqual(texture.height, sourceInfo.height,
                           "Node \(nodeID): height")
            XCTAssertEqual(texture.pixelFormat, sourceInfo.pixelFormat,
                           "Node \(nodeID): pixelFormat")
            XCTAssertTrue(texture.usage.contains(.shaderRead))
            XCTAssertTrue(texture.usage.contains(.shaderWrite))
        }
    }

    // MARK: - Final-node segregation

    /// Intermediate-textures list excludes the final node's
    /// texture. Caller keeps the final; intermediates return to
    /// the pool.
    func testIntermediateTexturesExcludeFinalNode() throws {
        let graph = Fx.linearPixelLocalChain(length: 4)
        let allocation = try allocator.allocate(graph: graph, sourceInfo: sourceInfo)

        // Identify the final texture by ObjectIdentifier.
        let finalTexID = ObjectIdentifier(allocation.mapping[graph.finalID]!)
        let intermediateIDs = Set(allocation.intermediateTextures.map {
            ObjectIdentifier($0)
        })

        XCTAssertFalse(
            intermediateIDs.contains(finalTexID),
            "Final node's texture must not appear in the release list"
        )

        // Unique intermediate count = buckets - 1 (the final's
        // bucket stays with the caller).
        XCTAssertEqual(
            allocation.intermediateTextures.count,
            allocation.plan.uniqueBucketCount - 1
        )
    }

    // MARK: - Release & pool return

    /// After `scheduleRelease(...)` fires on CB completion, the
    /// intermediate textures return to the pool. Verified by
    /// counting pooled textures before and after.
    func testScheduleReleaseReturnsTexturesOnCommandBufferCompletion() throws {
        // Pre-state: empty pool.
        XCTAssertEqual(pool.cachedTextureCount, 0)

        let graph = Fx.linearPixelLocalChain(length: 3)
        let allocation = try allocator.allocate(graph: graph, sourceInfo: sourceInfo)

        // Encode a no-op command buffer and schedule release.
        guard let queue = Device.shared.metalDevice.makeCommandQueue() else {
            throw XCTSkip("No command queue")
        }
        let cb = queue.makeCommandBuffer()!
        allocator.scheduleRelease(allocation, commandBuffer: cb)

        // Before commit: textures still "in use" (not yet
        // released to pool).
        XCTAssertEqual(pool.cachedTextureCount, 0,
                       "Release is deferred; pool should still be empty before CB commits")

        cb.commit()
        cb.waitUntilCompleted()

        // After completion: intermediate textures return.
        XCTAssertEqual(
            pool.cachedTextureCount,
            allocation.intermediateTextures.count,
            "Intermediate textures should be enqueued back into the pool after CB completes"
        )
    }

    // MARK: - Realistic HS + Clarity chain

    /// Lowering + optimising an HS + Clarity chain, then
    /// allocating, must produce a mapping whose texture count
    /// beats the "no-aliasing" baseline (one-per-node).
    func testHSAndClarityChainReducesTextureCountViaAliasing() throws {
        let steps: [AnyFilter] = [
            .multi(HighlightShadowFilter(highlights: 40)),
            .multi(ClarityFilter(intensity: 30)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: sourceInfo))
        let optimised = Optimizer.optimize(lowered)

        let allocation = try allocator.allocate(
            graph: optimised,
            sourceInfo: sourceInfo
        )
        let uniqueTextures = Set(allocation.mapping.values.map { ObjectIdentifier($0) }).count

        XCTAssertLessThan(
            uniqueTextures, optimised.nodes.count,
            "Aliasing should reduce physical texture count below node count"
        )
    }
}
