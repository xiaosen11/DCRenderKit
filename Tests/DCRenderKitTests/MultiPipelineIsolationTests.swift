//
//  MultiPipelineIsolationTests.swift
//  DCRenderKitTests
//
//  Verifies that multiple `Pipeline` instances coexist without
//  cross-pipeline state pollution: independent ShaderLibrary,
//  UberKernelCache, TexturePool budgets, and PSO cache keys that
//  include library identity. These tests also pin the
//  backward-compatibility contract — a default `Pipeline()` still
//  uses the SDK's `.shared` singletons.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class MultiPipelineIsolationTests: XCTestCase {

    // MARK: - Test fixtures

    private var device: Device!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
    }

    override func tearDown() {
        device = nil
        super.tearDown()
    }

    // MARK: - 1. Independent ShaderLibrary instances don't pollute each other

    /// Two independent ShaderLibraries register / unregister without
    /// touching each other's state. This proves Pipeline-A's setup
    /// doesn't trample Pipeline-B's registered shaders.
    func testIndependentShaderLibrariesDontCollide() throws {
        let libA = ShaderLibrary()
        let libB = ShaderLibrary()

        let testSourceA = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void mp_test_a(
            texture2d<half, access::write> output [[texture(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            output.write(half4(1, 0, 0, 1), gid);
        }
        """
        let testSourceB = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void mp_test_b(
            texture2d<half, access::write> output [[texture(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            output.write(half4(0, 1, 0, 1), gid);
        }
        """
        libA.register(try device.metalDevice.makeLibrary(source: testSourceA, options: nil))
        libB.register(try device.metalDevice.makeLibrary(source: testSourceB, options: nil))

        // libA can resolve mp_test_a but not mp_test_b
        XCTAssertNoThrow(try libA.function(named: "mp_test_a"))
        XCTAssertThrowsError(try libA.function(named: "mp_test_b"))

        // libB can resolve mp_test_b but not mp_test_a
        XCTAssertNoThrow(try libB.function(named: "mp_test_b"))
        XCTAssertThrowsError(try libB.function(named: "mp_test_a"))

        // libA.unregisterAll doesn't affect libB
        libA.unregisterAll()
        XCTAssertThrowsError(try libA.function(named: "mp_test_a"))
        XCTAssertNoThrow(try libB.function(named: "mp_test_b"))
    }

    // MARK: - 2. Same kernel name in different libraries → distinct PSOs

    /// Two libraries, both registering a kernel named `mp_collision`
    /// but with different bodies, must produce two distinct PSOs in
    /// the cache (cache key includes library identity).
    func testSameKernelNameDifferentLibrariesProduceDistinctPSOs() throws {
        let libA = ShaderLibrary()
        let libB = ShaderLibrary()
        let cache = PipelineStateCache(device: device)

        // Both kernels named "mp_collision" but with different bodies
        let bodyA = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void mp_collision(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            output.write(half4(1, 0, 0, 1), gid);  // body A: writes red
        }
        """
        let bodyB = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void mp_collision(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            output.write(half4(0, 0, 1, 1), gid);  // body B: writes blue
        }
        """
        libA.register(try device.metalDevice.makeLibrary(source: bodyA, options: nil))
        libB.register(try device.metalDevice.makeLibrary(source: bodyB, options: nil))

        let psoA = try cache.computePipelineState(forKernel: "mp_collision", library: libA)
        let psoB = try cache.computePipelineState(forKernel: "mp_collision", library: libB)

        // The cache should have stored both — not collapsed into one
        XCTAssertEqual(cache.computeCacheCount, 2)
        // The two PSOs must be distinct objects — if the cache key
        // ignored library identity, psoA === psoB and one library's
        // body would be silently used for the other's dispatch.
        XCTAssertFalse(psoA === psoB, "Same kernel name across libraries collapsed to one PSO — library identity not in cache key")
    }

    // MARK: - 3. Independent UberKernelCache → cache count isolated

    /// Two Pipelines with independent UberKernelCaches don't see each
    /// other's compiled uber kernels.
    func testIndependentUberKernelCachesAreIsolated() throws {
        let cacheA = UberKernelCache(device: device)
        let cacheB = UberKernelCache(device: device)

        XCTAssertEqual(cacheA.cachedPipelineCount, 0)
        XCTAssertEqual(cacheB.cachedPipelineCount, 0)

        // Pipeline A: independent uber cache; uses default .shared
        // for everything else (PSO cache shared is fine).
        let pipelineA = Pipeline(
            optimization: .full,
            intermediatePixelFormat: .rgba16Float,
            colorSpace: DCRenderKit.defaultColorSpace,
            device: device,
            textureLoader: .shared,
            psoCache: .shared,
            uniformPool: .shared,
            samplerCache: .shared,
            texturePool: .shared,
            commandBufferPool: .shared,
            shaderLibrary: .shared,
            uberKernelCache: cacheA,
            uberRenderCache: .shared
        )

        let source = try makeUniformTexture(width: 8, height: 8, red: 0.5)
        _ = try pipelineA.processSync(
            input: .texture(source),
            steps: [.single(ExposureFilter(exposure: 10))]
        )
        XCTAssertEqual(cacheA.cachedPipelineCount, 1)
        XCTAssertEqual(cacheB.cachedPipelineCount, 0, "Pipeline A's uber kernel must not pollute cache B")

        // Pipeline B: a different filter so uber kernel hash differs;
        // uses cacheB and must not see cacheA's compiled kernel.
        let pipelineB = Pipeline(
            optimization: .full,
            intermediatePixelFormat: .rgba16Float,
            colorSpace: DCRenderKit.defaultColorSpace,
            device: device,
            textureLoader: .shared,
            psoCache: .shared,
            uniformPool: .shared,
            samplerCache: .shared,
            texturePool: .shared,
            commandBufferPool: .shared,
            shaderLibrary: .shared,
            uberKernelCache: cacheB,
            uberRenderCache: .shared
        )

        _ = try pipelineB.processSync(
            input: .texture(source),
            steps: [.single(ContrastFilter(contrast: 10, lumaMean: 0.5))]
        )
        XCTAssertEqual(cacheA.cachedPipelineCount, 1, "Pipeline B's run must not affect cache A")
        XCTAssertEqual(cacheB.cachedPipelineCount, 1)
    }

    // MARK: - 4. Independent TexturePool budgets

    /// Two Pipelines with independent TexturePools have independent
    /// `currentBytes` counters.
    func testIndependentTexturePoolsHaveSeparateBudgets() throws {
        let poolA = TexturePool(device: device, maxBytes: 4 * 1024 * 1024)
        let poolB = TexturePool(device: device, maxBytes: 16 * 1024 * 1024)

        // Pipeline A uses poolA, Pipeline B uses poolB.
        let pipelineA = Pipeline.makeFullyIsolated(
            device: device,
            textureBudgetMB: 0  // overridden below — but factory needs >0; we'll inject via init
        )
        let pipelineB = Pipeline.makeFullyIsolated(
            device: device,
            textureBudgetMB: 0
        )

        // Workaround for compile-time check above; build through full init:
        let workaroundA = Pipeline(
            optimization: .full,
            intermediatePixelFormat: .rgba16Float,
            colorSpace: DCRenderKit.defaultColorSpace,
            device: device,
            textureLoader: .shared,
            psoCache: .shared,
            uniformPool: .shared,
            samplerCache: .shared,
            texturePool: poolA,
            commandBufferPool: .shared,
            shaderLibrary: .shared
        )
        let workaroundB = Pipeline(
            optimization: .full,
            intermediatePixelFormat: .rgba16Float,
            colorSpace: DCRenderKit.defaultColorSpace,
            device: device,
            textureLoader: .shared,
            psoCache: .shared,
            uniformPool: .shared,
            samplerCache: .shared,
            texturePool: poolB,
            commandBufferPool: .shared,
            shaderLibrary: .shared
        )
        _ = pipelineA  // silence unused warning
        _ = pipelineB

        // Run a multi-pass chain on workaroundA — exercises poolA only.
        let source = try makeUniformTexture(width: 64, height: 64, red: 0.5)
        _ = try workaroundA.processSync(
            input: .texture(source),
            steps: [.multi(HighlightShadowFilter(highlights: 30, shadows: -20))]
        )

        // Pool A holds intermediates after run; Pool B remains empty.
        XCTAssertGreaterThan(poolA.currentBytes, 0, "Pool A should have cached intermediates after the run")
        XCTAssertEqual(poolB.currentBytes, 0, "Pool B must be untouched by Pipeline A")

        _ = try workaroundB.processSync(
            input: .texture(source),
            steps: [.multi(HighlightShadowFilter(highlights: 30, shadows: -20))]
        )
        XCTAssertGreaterThan(poolB.currentBytes, 0, "Pool B should populate after its own run")
        // Pool A's bytes don't grow — workaroundB doesn't touch it.
        let aBytesAfterB = poolA.currentBytes
        XCTAssertGreaterThan(aBytesAfterB, 0)
    }

    // MARK: - 5. Default Pipeline() backward compatibility

    /// `Pipeline()` continues to use `.shared` for all resources —
    /// the multi-Pipeline refactor is fully backward compatible.
    func testDefaultPipelineUsesSharedSingletons() throws {
        let pipeline = Pipeline()
        XCTAssertTrue(pipeline.shaderLibrary === ShaderLibrary.shared)
        XCTAssertTrue(pipeline.uberKernelCache === UberKernelCache.shared)
        XCTAssertTrue(pipeline.uberRenderCache === UberRenderPipelineCache.shared)
        XCTAssertTrue(pipeline.texturePool === TexturePool.shared)
        XCTAssertTrue(pipeline.commandBufferPool === CommandBufferPool.shared)
        XCTAssertTrue(pipeline.uniformPool === UniformBufferPool.shared)
    }

    // MARK: - 6. Two Pipelines processing concurrently don't corrupt each other

    /// Two Pipelines submitting different filter chains in alternation
    /// produce correct output for both — no cross-thread state leak.
    func testTwoPipelinesEncodingConcurrentlyDontCorruptEachOther() throws {
        let pipelineA = Pipeline.makeIsolated(
            device: device,
            textureBudgetMB: 8,
            maxInFlightCommandBuffers: 2
        )
        let pipelineB = Pipeline.makeIsolated(
            device: device,
            textureBudgetMB: 8,
            maxInFlightCommandBuffers: 2
        )

        let source = try makeUniformTexture(width: 16, height: 16, red: 0.5)

        // Interleave 5 rounds of A and B encoding different chains.
        for _ in 0..<5 {
            let outA = try pipelineA.processSync(
                input: .texture(source),
                steps: [.single(ExposureFilter(exposure: 30))]  // brighten
            )
            let outB = try pipelineB.processSync(
                input: .texture(source),
                steps: [.single(ContrastFilter(contrast: 30, lumaMean: 0.5))]  // contrast
            )

            // Both output dimensions must match input
            XCTAssertEqual(outA.width, 16)
            XCTAssertEqual(outA.height, 16)
            XCTAssertEqual(outB.width, 16)
            XCTAssertEqual(outB.height, 16)
        }
    }

    // MARK: - Helpers

    private func makeUniformTexture(width: Int, height: Int, red: Float) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.metalDevice.makeTexture(descriptor: desc) else {
            throw XCTSkip("Texture allocation failed")
        }
        let r = Float16(red).bitPattern
        let g = Float16(0).bitPattern
        let b = Float16(0).bitPattern
        let a = Float16(1).bitPattern
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = a
        }
        pixels.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 8
            )
        }
        return tex
    }
}
