//
//  ResourceManagementTests.swift
//  DCRenderKitTests
//
//  Tests for Device, PipelineStateCache, TexturePool, SamplerCache,
//  UniformBufferPool, and CommandBufferPool.
//

import XCTest
@testable import DCRenderKit
import Metal

// All tests in this file require a real Metal device. Skip gracefully on
// headless CI environments.

final class DeviceTests: XCTestCase {

    func testSharedDeviceExists() throws {
        try XCTSkipUnless(Device.tryShared != nil, "Metal device required")
        let device = Device.shared
        XCTAssertFalse(device.name.isEmpty)
    }

    func testCommandQueueLazyInit() throws {
        guard let device = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        let queue1 = device.commandQueue
        let queue2 = device.commandQueue
        XCTAssertTrue(queue1 === queue2, "commandQueue should be cached")
    }

    func testMakeCommandBuffer() throws {
        guard let device = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        let buffer = try device.makeCommandBuffer()
        XCTAssertNotNil(buffer)
    }

    func testMakeCommandQueueWithLabel() throws {
        guard let device = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        let queue = try device.makeCommandQueue(label: "test.queue")
        XCTAssertEqual(queue.label, "test.queue")
    }
}

final class PipelineStateCacheTests: XCTestCase {

    var device: Device!
    var cache: PipelineStateCache!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        cache = PipelineStateCache(device: d)
        ShaderLibrary.shared.unregisterAll()

        // Register a tiny test library with a known kernel.
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void test_identity_kernel(
            texture2d<half, access::write> out [[texture(0)]],
            texture2d<half, access::read>  in  [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
            out.write(in.read(gid), gid);
        }
        """
        let lib = try d.metalDevice.makeLibrary(source: source, options: nil)
        ShaderLibrary.shared.register(lib)
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        cache = nil
        device = nil
        super.tearDown()
    }

    func testComputePSOCompilesAndCaches() throws {
        XCTAssertEqual(cache.computeCacheCount, 0)

        let pso1 = try cache.computePipelineState(forKernel: "test_identity_kernel")
        XCTAssertEqual(cache.computeCacheCount, 1)

        let pso2 = try cache.computePipelineState(forKernel: "test_identity_kernel")
        XCTAssertTrue(pso1 === pso2, "Second lookup should return cached PSO")
        XCTAssertEqual(cache.computeCacheCount, 1)
    }

    func testComputePSOMissingKernelThrows() {
        do {
            _ = try cache.computePipelineState(forKernel: "__not_a_real_kernel__")
            XCTFail("Expected throw")
        } catch PipelineError.pipelineState(.functionNotFound(let name)) {
            XCTAssertEqual(name, "__not_a_real_kernel__")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testClearResetsCacheCount() throws {
        _ = try cache.computePipelineState(forKernel: "test_identity_kernel")
        XCTAssertEqual(cache.computeCacheCount, 1)
        cache.clear()
        XCTAssertEqual(cache.computeCacheCount, 0)
    }
}

final class TexturePoolTests: XCTestCase {

    var device: Device!
    var pool: TexturePool!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        // Small maxBytes so eviction tests can fire predictably.
        pool = TexturePool(device: d, maxBytes: 4 * 1024 * 1024)  // 4 MB
    }

    override func tearDown() {
        pool = nil
        device = nil
        super.tearDown()
    }

    func testDequeueAllocatesNewTexture() throws {
        let spec = TexturePoolSpec(width: 100, height: 100)
        let tex = try pool.dequeue(spec: spec)
        XCTAssertEqual(tex.width, 100)
        XCTAssertEqual(tex.height, 100)
        XCTAssertEqual(tex.pixelFormat, .rgba16Float)
    }

    func testEnqueueThenDequeueReuses() throws {
        let spec = TexturePoolSpec(width: 100, height: 100)
        let tex1 = try pool.dequeue(spec: spec)
        pool.enqueue(tex1)

        let tex2 = try pool.dequeue(spec: spec)
        XCTAssertTrue(tex1 === tex2, "Same-spec textures should be reused")
    }

    func testDifferentSpecsDontConflict() throws {
        let spec1 = TexturePoolSpec(width: 100, height: 100)
        let spec2 = TexturePoolSpec(width: 200, height: 200)
        let tex1 = try pool.dequeue(spec: spec1)
        let tex2 = try pool.dequeue(spec: spec2)
        pool.enqueue(tex1)
        pool.enqueue(tex2)

        let reusedTex1 = try pool.dequeue(spec: spec1)
        XCTAssertTrue(reusedTex1 === tex1)
    }

    func testInvalidDimensionsThrow() {
        let spec = TexturePoolSpec(width: 0, height: 100)
        do {
            _ = try pool.dequeue(spec: spec)
            XCTFail("Expected throw")
        } catch PipelineError.texture(.dimensionsInvalid) {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testClearResetsState() throws {
        let spec = TexturePoolSpec(width: 100, height: 100)
        let tex = try pool.dequeue(spec: spec)
        pool.enqueue(tex)

        XCTAssertEqual(pool.cachedTextureCount, 1)
        pool.clear()
        XCTAssertEqual(pool.cachedTextureCount, 0)
        XCTAssertEqual(pool.currentBytes, 0)
    }

    func testMaxBytesEviction() throws {
        // 256x256 rgba16Float = 256*256*8 = 524,288 bytes (~0.5 MB)
        // With 4 MB cap, we can hold ~8 such textures.
        let spec = TexturePoolSpec(width: 256, height: 256)
        var textures: [MTLTexture] = []
        for _ in 0..<16 {
            textures.append(try pool.dequeue(spec: spec))
        }
        for tex in textures {
            pool.enqueue(tex)
        }
        XCTAssertLessThanOrEqual(
            pool.currentBytes,
            pool.maxBytes,
            "Eviction should keep bytes under limit"
        )
    }
}

final class SamplerCacheTests: XCTestCase {

    var device: Device!
    var cache: SamplerCache!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        cache = SamplerCache(device: d)
    }

    override func tearDown() {
        cache?.clear()
        cache = nil
        device = nil
        super.tearDown()
    }

    func testSamplerCreationAndCaching() throws {
        let config = SamplerConfig.linearClamp
        let s1 = try cache.sampler(for: config)
        let s2 = try cache.sampler(for: config)
        XCTAssertTrue(s1 === s2, "Same config should return cached sampler")
        XCTAssertEqual(cache.count, 1)
    }

    func testDifferentConfigsDontConflict() throws {
        _ = try cache.sampler(for: .linearClamp)
        _ = try cache.sampler(for: .nearestClamp)
        _ = try cache.sampler(for: .linearRepeat)
        XCTAssertEqual(cache.count, 3)
    }

    func testBuiltInConfigs() {
        XCTAssertEqual(SamplerConfig.linearClamp.minFilter, .linear)
        XCTAssertEqual(SamplerConfig.nearestClamp.minFilter, .nearest)
        XCTAssertEqual(SamplerConfig.linearRepeat.sAddressMode, .repeat)
    }
}

final class UniformBufferPoolTests: XCTestCase {

    var device: Device!
    var queue: MTLCommandQueue!
    var pool: UniformBufferPool!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        queue = try XCTUnwrap(d.metalDevice.makeCommandQueue())
        pool = UniformBufferPool(
            device: d,
            capacity: 3,
            maxBuffers: 8,
            bufferSize: 256
        )
    }

    override func tearDown() {
        pool = nil
        queue = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Empty / single-use paths

    func testEmptyUniformsReturnsNil() throws {
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let result = try pool.nextBuffer(for: .empty, commandBuffer: cb)
        XCTAssertNil(result)
        cb.commit()
    }

    func testPODUniformsBind() throws {
        struct Params { var a: Float = 1.0; var b: Float = 2.0 }
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let u = FilterUniforms(Params())
        let result = try pool.nextBuffer(for: u, commandBuffer: cb)
        let binding = try XCTUnwrap(result)

        let ptr = binding.buffer.contents().advanced(by: binding.offset)
            .assumingMemoryBound(to: Params.self)
        XCTAssertEqual(ptr.pointee.a, 1.0)
        XCTAssertEqual(ptr.pointee.b, 2.0)
        cb.commit()
    }

    // MARK: - Fence guarantees — the whole point of the refactor

    func testSameCommandBufferGetsDistinctBuffers() throws {
        // The bug that originally lived here: a single command buffer
        // encoding N > capacity dispatches got overwriting buffer slots.
        // Contract now: within one command buffer, every request returns
        // a distinct backing buffer.
        struct P { var v: Int32 = 0 }
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        var seen: [MTLBuffer] = []
        for i in 0..<6 {
            var p = P(); p.v = Int32(i)
            let binding = try XCTUnwrap(
                pool.nextBuffer(for: FilterUniforms(p), commandBuffer: cb)
            )
            seen.append(binding.buffer)
        }
        cb.commit()
        cb.waitUntilCompleted()

        // All six backing buffers must be unique.
        for i in 0..<seen.count {
            for j in (i + 1)..<seen.count {
                XCTAssertFalse(seen[i] === seen[j], "buffers \(i) and \(j) aliased")
            }
        }
    }

    func testPoolGrowsBeyondInitialCapacity() throws {
        // Initial capacity 3, maxBuffers 8. A 5-dispatch command buffer
        // must force growth from 3 → 5 slots.
        struct P { var v: Float = 0 }
        XCTAssertEqual(pool.currentSlotCount, 3)

        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        for _ in 0..<5 {
            _ = try pool.nextBuffer(for: FilterUniforms(P()), commandBuffer: cb)
        }
        XCTAssertEqual(pool.currentSlotCount, 5)
        cb.commit()
    }

    func testReservationsReleaseAfterCommandBufferCompletes() throws {
        // 3 dispatches on one command buffer → 3 reservations. After
        // completion, the pool must have 0 reservations (all slots free
        // again).
        struct P { var v: Float = 0 }
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        for _ in 0..<3 {
            _ = try pool.nextBuffer(for: FilterUniforms(P()), commandBuffer: cb)
        }
        XCTAssertEqual(pool.reservedSlotCount, 3)

        cb.commit()
        cb.waitUntilCompleted()

        // `addCompletedHandler` is invoked on an unspecified GPU thread;
        // give it up to half a second before declaring the release failed.
        // Capture `pool` through a local constant so the @Sendable
        // background closure doesn't have to reach into `self` (the test
        // case itself is not Sendable).
        let releasedExpectation = expectation(description: "reservations released")
        let poolRef = pool!
        DispatchQueue.global().async {
            for _ in 0..<50 {
                if poolRef.reservedSlotCount == 0 {
                    releasedExpectation.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        wait(for: [releasedExpectation], timeout: 1.0)
        XCTAssertEqual(pool.reservedSlotCount, 0)
    }

    func testSeparateCommandBuffersCanShareSlotsAfterCompletion() throws {
        struct P { var v: Float = 0 }

        // First command buffer reserves all 3 initial slots.
        let cbA = try XCTUnwrap(queue.makeCommandBuffer())
        var firstWave: [MTLBuffer] = []
        for _ in 0..<3 {
            let binding = try XCTUnwrap(
                pool.nextBuffer(for: FilterUniforms(P()), commandBuffer: cbA)
            )
            firstWave.append(binding.buffer)
        }
        cbA.commit()
        cbA.waitUntilCompleted()
        // Spin until reservations have actually released (handler is async).
        let deadline = Date().addingTimeInterval(1.0)
        while pool.reservedSlotCount != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(pool.reservedSlotCount, 0)

        // Second command buffer: slots should be reused (not grow).
        let slotsBefore = pool.currentSlotCount
        let cbB = try XCTUnwrap(queue.makeCommandBuffer())
        var secondWave: [MTLBuffer] = []
        for _ in 0..<3 {
            let binding = try XCTUnwrap(
                pool.nextBuffer(for: FilterUniforms(P()), commandBuffer: cbB)
            )
            secondWave.append(binding.buffer)
        }
        XCTAssertEqual(pool.currentSlotCount, slotsBefore, "pool should not have grown")

        // At least one buffer from the second wave should be identical to
        // one from the first wave — the pool reused slots rather than
        // allocating new ones.
        let reusedAtLeastOne = secondWave.contains { b in
            firstWave.contains { $0 === b }
        }
        XCTAssertTrue(reusedAtLeastOne)
        cbB.commit()
    }

    func testFallbackToOneOffAtCapacityCap() throws {
        // maxBuffers = 8. 10 requests on one command buffer should grow
        // to 8 and then fall back to one-off for the last two without
        // throwing.
        struct P { var v: Float = 0 }
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        for _ in 0..<10 {
            let binding = try pool.nextBuffer(
                for: FilterUniforms(P()),
                commandBuffer: cb
            )
            XCTAssertNotNil(binding)
        }
        XCTAssertLessThanOrEqual(pool.currentSlotCount, 8)
        cb.commit()
    }

    // MARK: - Oversize path

    func testOversizedUniformsGoThroughOneOff() throws {
        struct BigParams {
            var data: (UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64, UInt64, UInt64,
                       UInt64, UInt64) = (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            )
        }
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let u = FilterUniforms(BigParams())
        XCTAssertGreaterThan(u.byteCount, 256)
        let result = try pool.nextBuffer(for: u, commandBuffer: cb)
        XCTAssertNotNil(result)
        // Oversize path doesn't hold a reservation (it's a one-off buffer).
        XCTAssertEqual(pool.reservedSlotCount, 0)
        cb.commit()
    }
}

final class CommandBufferPoolTests: XCTestCase {

    var device: Device!
    var pool: CommandBufferPool!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        pool = CommandBufferPool(device: d, maxInFlight: 2)
    }

    override func tearDown() {
        pool = nil
        device = nil
        super.tearDown()
    }

    func testMakeCommandBufferWithLabel() throws {
        let buffer = try pool.makeCommandBuffer(label: "test.cmd")
        XCTAssertEqual(buffer.label, "test.cmd")
        buffer.commit()
    }

    func testEnqueueConvenience() throws {
        var encoded = false
        try pool.enqueue(label: "test.enqueue") { buffer in
            XCTAssertEqual(buffer.label, "test.enqueue")
            encoded = true
        }
        XCTAssertTrue(encoded)
    }

    func testEnqueueAndWaitCompletesSync() throws {
        try pool.enqueueAndWait(label: "sync") { _ in
            // no-op encoding
        }
        // If we get here without hanging, the wait worked.
    }
}
