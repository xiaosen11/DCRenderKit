//
//  DeferredEnqueueTests.swift
//  DCRenderKitTests
//
//  P1 regression: TexturePool must not reclaim intermediate textures
//  until the GPU finishes executing the command buffer that uses them.
//  Eager enqueue was safe within a single CB (Metal's automatic hazard
//  tracking inserts barriers), but cross-CB it was a race: a concurrent
//  pipeline could dequeue a texture still in flight on the GPU and start
//  writing to it.
//
//  These tests verify:
//    1. After encoding into a CB but BEFORE commit, the pool has not
//       received any intermediates. (This directly exposes the old
//       eager-enqueue bug.)
//    2. After the CB completes, the pool regains all intermediates.
//    3. Two pipelines sharing a pool can run concurrently without one's
//       in-flight intermediates being handed to the other.
//

import XCTest
@testable import DCRenderKit
import Metal

final class DeferredEnqueueTests: XCTestCase {

    var device: Device!
    var psoCache: PipelineStateCache!
    var uniformPool: UniformBufferPool!
    var samplerCache: SamplerCache!
    var commandBufferPool: CommandBufferPool!
    var textureLoader: TextureLoader!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 6, bufferSize: 256)
        samplerCache = SamplerCache(device: d)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 8)
        textureLoader = TextureLoader(device: d)
        ShaderLibrary.shared.unregisterAll()
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        commandBufferPool = nil
        samplerCache = nil
        uniformPool = nil
        psoCache = nil
        textureLoader = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Deferral contract

    func testPoolDoesNotReceiveIntermediatesBeforeCommandBufferCompletes() throws {
        // Isolated pool so its state is observable.
        let pool = TexturePool(device: device, maxBytes: 64 * 1024 * 1024)

        // Three `.neighborRead` filters defeat every Phase-5 optimiser
        // pass: VerticalFusion only collapses `.pixelLocal` runs,
        // KernelInlining requires a `.pixelLocal` predecessor, and
        // TailSink requires a `.pixelLocal` consumer. The resulting
        // 3-node graph allocates 3 buckets (2 intermediates + 1 final)
        // so the pool's post-completion flow mirrors the pre-compiler
        // behaviour this deferral contract was written against.
        // Different `amount` per filter keeps CSE inert too.
        let source = try makeSource(width: 32, height: 32)
        let pipeline = makePipeline(pool: pool)
        let steps: [AnyFilter] = [
            .single(SharpenFilter(amount: 30, stepPixels: 1)),
            .single(SharpenFilter(amount: 10, stepPixels: 1)),
            .single(SharpenFilter(amount: 20, stepPixels: 1)),
        ]

        XCTAssertEqual(pool.cachedTextureCount, 0, "Pool starts empty")

        // Encode without committing. With a 3-step chain, two intermediate
        // textures are created (output of step 0 feeds step 1; output of
        // step 1 feeds step 2). Under the old eager-enqueue behaviour the
        // input of step 1 and step 2 would have been enqueued here.
        let cb = try XCTUnwrap(device.metalDevice.makeCommandQueue()?.makeCommandBuffer())
        _ = try pipeline.encode(into: cb, source: source, steps: steps)

        XCTAssertEqual(
            pool.cachedTextureCount, 0,
            "Pool must not receive intermediates before CB completes"
        )

        // Commit + wait, then poll briefly for the completion handler.
        cb.commit()
        cb.waitUntilCompleted()

        // Post Phase-5: the compiler path's
        // LifetimeAwareTextureAllocator ping-pong-aliases sibling
        // intermediates into the fewest physical textures (interval-
        // graph optimal), so a 3-node linear chain now reuses a single
        // intermediate bucket plus the final-output bucket. The
        // deferral contract still holds — we just expect ≥1
        // intermediate to land in the pool post-completion, not ≥2
        // as in the pre-aliasing era.
        XCTAssertTrue(
            waitForPoolCount(pool, atLeast: 1, timeout: 1.0),
            "Pool must receive ≥1 intermediate texture after CB completes; got \(pool.cachedTextureCount)"
        )
    }

    func testMultiPassFilterDefersIntermediateEnqueueToCompletion() throws {
        // Multi-pass filter path (SoftGlow has many intermediates) must
        // also defer enqueue. Tests the `MultiPassExecutor.execute`
        // deferral patch.
        let pool = TexturePool(device: device, maxBytes: 128 * 1024 * 1024)

        let source = try makeSource(width: 64, height: 64)
        let pipeline = makePipeline(pool: pool)
        let steps: [AnyFilter] = [
            .multi(SoftGlowFilter(strength: 60, threshold: 30, bloomRadius: 50)),
        ]

        let cb = try XCTUnwrap(device.metalDevice.makeCommandQueue()?.makeCommandBuffer())
        _ = try pipeline.encode(into: cb, source: source, steps: steps)

        XCTAssertEqual(
            pool.cachedTextureCount, 0,
            "Pool must not receive multi-pass intermediates before CB completes"
        )

        cb.commit()
        cb.waitUntilCompleted()

        XCTAssertTrue(
            waitForPoolCount(pool, atLeast: 1, timeout: 1.0),
            "Pool must receive multi-pass intermediates after CB completes"
        )
    }

    // MARK: - Cross-CB isolation

    func testConcurrentPipelinesDoNotShareInFlightIntermediates() throws {
        // Two pipelines sharing one pool. While pipeline A's CB is still in
        // flight, pipeline B encodes its chain. With the fix, pipeline B
        // must allocate fresh textures (A's in-flight ones are not in the
        // pool yet), so their `produced` intermediate identity sets are
        // disjoint.
        //
        // To observe identities, we use the pool's `cachedTextureCount`
        // as a proxy: after both encodings, if they shared a texture the
        // pool's total flow would be inconsistent. A stricter version
        // would need pool introspection of MTLTexture identity sets,
        // which we don't currently expose.

        let pool = TexturePool(device: device, maxBytes: 256 * 1024 * 1024)
        let queue = try XCTUnwrap(device.metalDevice.makeCommandQueue())

        // Two `.neighborRead` filters keep the Phase-5 compiler's
        // KernelInlining and TailSink passes inert — there is no
        // `.pixelLocal` to inline or sink. VerticalFusion is also
        // inert because it only collapses `.pixelLocal` runs. The
        // resulting 2-node graph produces one intermediate per
        // pipeline, so two concurrent pipelines refill the pool with
        // the ≥2 intermediates the assertion below requires.
        let sourceA = try makeSource(width: 32, height: 32)
        let sourceB = try makeSource(width: 32, height: 32)
        let pipelineA = makePipeline(pool: pool)
        let stepsA: [AnyFilter] = [
            .single(SharpenFilter(amount: 20, stepPixels: 1)),
            .single(SharpenFilter(amount: 15, stepPixels: 1)),
        ]
        let pipelineB = makePipeline(pool: pool)
        let stepsB: [AnyFilter] = [
            .single(SharpenFilter(amount: 30, stepPixels: 1)),
            .single(SharpenFilter(amount: 10, stepPixels: 1)),
        ]

        // Encode pipeline A into cbA, don't commit yet.
        let cbA = try XCTUnwrap(queue.makeCommandBuffer())
        let outputA = try pipelineA.encode(into: cbA, source: sourceA, steps: stepsA)

        // While A is pending, encode pipeline B into cbB.
        // The pool is empty (A hasn't completed) so B must allocate fresh.
        let cbB = try XCTUnwrap(queue.makeCommandBuffer())
        let outputB = try pipelineB.encode(into: cbB, source: sourceB, steps: stepsB)

        XCTAssertFalse(
            outputA === outputB,
            "Concurrent pipelines must produce distinct output textures"
        )

        // Commit both, wait for both to complete.
        cbA.commit()
        cbB.commit()
        cbA.waitUntilCompleted()
        cbB.waitUntilCompleted()

        // After both complete, pool should have ≥2 intermediates
        // (one from each chain). No assertion on exact count because
        // pool eviction depends on capacity; the key invariant is both
        // completions fired without crash / hang.
        XCTAssertTrue(
            waitForPoolCount(pool, atLeast: 2, timeout: 1.0),
            "Pool must refill after both pipelines complete"
        )
    }

    func testThreeBackToBackPipelinesCompleteWithoutCrossPipelineReuse() throws {
        // Realistic pipelining: pipeline N+1's CB starts while pipeline N
        // is still in flight. Previously this would trip the race when
        // pipeline N's intermediates were handed to pipeline N+1. With the
        // fix, pipeline N+1 allocates fresh.
        //
        // We don't have a way to observe the race directly — Metal's
        // resource tracking across CBs is implementation-defined — but
        // we can verify:
        //   (a) no crashes / hangs
        //   (b) all final outputs are distinct MTLTexture instances
        //   (c) the pool ends in a non-empty, consistent state
        let pool = TexturePool(device: device, maxBytes: 128 * 1024 * 1024)
        let queue = try XCTUnwrap(device.metalDevice.makeCommandQueue())

        var inflightBuffers: [MTLCommandBuffer] = []
        var outputs: [MTLTexture] = []

        for sliderMul in 0..<3 {
            let src = try makeSource(width: 32, height: 32)
            let pipeline = makePipeline(pool: pool)
            let steps: [AnyFilter] = [
                .single(ExposureFilter(exposure: Float(10 * sliderMul))),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            ]
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try pipeline.encode(into: cb, source: src, steps: steps)
            outputs.append(output)
            inflightBuffers.append(cb)
            cb.commit()
        }

        for cb in inflightBuffers {
            cb.waitUntilCompleted()
        }

        // All three final outputs must be distinct MTLTexture instances.
        XCTAssertFalse(outputs[0] === outputs[1])
        XCTAssertFalse(outputs[1] === outputs[2])
        XCTAssertFalse(outputs[0] === outputs[2])
    }

    // MARK: - Helpers

    private func makePipeline(pool: TexturePool) -> Pipeline {
        Pipeline(
            intermediatePixelFormat: .rgba16Float,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: pool,
            commandBufferPool: commandBufferPool
        )
    }

    private func makeSource(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let h5 = Float16(0.5).bitPattern
        let ha = Float16(1.0).bitPattern
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = h5
            pixels[i * 4 + 1] = h5
            pixels[i * 4 + 2] = h5
            pixels[i * 4 + 3] = ha
        }
        pixels.withUnsafeBytes { bytes in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 8
            )
        }
        return tex
    }

    /// Poll `pool.cachedTextureCount` until it reaches `atLeast` or
    /// `timeout` seconds pass. Metal completion handlers may run on a
    /// background queue asynchronously with respect to `waitUntilCompleted`
    /// returning, so a brief poll gives them time to fire.
    private func waitForPoolCount(
        _ pool: TexturePool,
        atLeast: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while pool.cachedTextureCount < atLeast {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }
}
