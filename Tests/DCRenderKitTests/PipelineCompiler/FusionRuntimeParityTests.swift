//
//  FusionRuntimeParityTests.swift
//  DCRenderKitTests
//
//  Runtime parity gate for `KernelInlining` (head fusion) and
//  `TailSink` (tail fusion). Each test runs the same filter chain
//  twice — once with `optimization: .full` (the optimiser fires and
//  the source-tap codegen produces a fused uber kernel), once with
//  `optimization: .none` (every filter dispatches as its own pass)
//  — and asserts the two outputs agree to Float16 margin.
//
//  Why this exists: the fused kernel and the per-pass dispatch path
//  agree on the *math* but rely on three independently-edited code
//  surfaces staying consistent:
//
//    1. `MetalSourceBuilder.buildNeighborReadWithSource` decides which
//       uniform buffer slot each fused body reads from (`uHead` at
//       buffer(1), `uTail` at the next slot).
//    2. `ComputeBackend.bindUniforms` sets uniforms at corresponding
//       slot indices.
//    3. `KernelInlining` / `TailSink` populate
//       `Node.inlinedBodyBeforeSample` / `Node.tailSinkedBody` in a
//       specific head-then-tail order.
//
//  If any one of those surfaces drifts (e.g. someone swaps head/tail
//  ordering in the codegen but not in `bindUniforms`) the kernel
//  reads the wrong filter's uniforms, the output pixel diverges from
//  the per-pass baseline, and these tests fail.
//
//  Other PSO-cache hash drift would also surface here: a missing
//  `(head, tail)` discriminator would let a stale unfused kernel
//  return for what should be a fused dispatch, and the colours would
//  diverge.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class FusionRuntimeParityTests: XCTestCase {

    private var device: Device!
    private var psoCache: PipelineStateCache!
    private var uniformPool: UniformBufferPool!
    private var samplerCache: SamplerCache!
    private var texturePool: TexturePool!
    private var commandBufferPool: CommandBufferPool!
    private var textureLoader: TextureLoader!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 4, bufferSize: 256)
        samplerCache = SamplerCache(device: d)
        texturePool = TexturePool(device: d, maxBytes: 32 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)
        UberKernelCache.shared.clear()
        UberRenderPipelineCache.shared.clear()
    }

    override func tearDown() {
        commandBufferPool = nil
        texturePool = nil
        samplerCache = nil
        uniformPool = nil
        psoCache = nil
        textureLoader = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Sanity: confirm optimiser actually fires

    /// Belt-and-braces. Each parity test below would silently pass if
    /// the optimiser stopped firing for the chain — both `.full` and
    /// `.none` paths would converge on the per-pass dispatch and
    /// Float16 rounding would line up trivially. Verifying the
    /// optimised graph carries the expected fusion marker turns the
    /// parity tests into actual codegen-vs-binding gates instead of
    /// no-ops.
    func testOptimiserActuallyFiresOnTheParityChains() throws {
        let source = TextureInfo(width: 16, height: 16, pixelFormat: .rgba16Float)

        // KI head fusion: Saturation → Sharpen → Sharpen carries
        // inlinedBodyBeforeSample after optimisation.
        let headChain: [AnyFilter] = [
            .single(SaturationFilter(saturation: 1.4)),
            .single(SharpenFilter(amount: 1.0, stepPixels: 1)),
        ]
        let headOpt = Optimizer.optimize(
            try XCTUnwrap(Lowering.lower(headChain, source: source))
        )
        XCTAssertTrue(
            headOpt.nodes.contains { $0.inlinedBodyBeforeSample != nil },
            "KernelInlining did not fire on Saturation→Sharpen — parity test trivially passes; investigate optimiser regression"
        )

        // TailSink: Sharpen → Saturation → Sharpen carries
        // tailSinkedBody after optimisation.
        let tailChain: [AnyFilter] = [
            .single(SharpenFilter(amount: 1.0, stepPixels: 1)),
            .single(SaturationFilter(saturation: 1.4)),
        ]
        let tailOpt = Optimizer.optimize(
            try XCTUnwrap(Lowering.lower(tailChain, source: source))
        )
        XCTAssertTrue(
            tailOpt.nodes.contains { $0.tailSinkedBody != nil },
            "TailSink did not fire on Sharpen→Saturation — parity test trivially passes; investigate optimiser regression"
        )

        // Combined: Vibrance → Sharpen → Saturation → Sharpen carries
        // BOTH markers after optimisation.
        let bothChain: [AnyFilter] = [
            .single(VibranceFilter(vibrance: 0.5)),
            .single(SharpenFilter(amount: 1.0, stepPixels: 1)),
            .single(SaturationFilter(saturation: 1.3)),
        ]
        let bothOpt = Optimizer.optimize(
            try XCTUnwrap(Lowering.lower(bothChain, source: source))
        )
        XCTAssertTrue(
            bothOpt.nodes.contains {
                $0.inlinedBodyBeforeSample != nil && $0.tailSinkedBody != nil
            },
            "Combined head+tail fusion did not produce a node with both markers; one or both passes regressed"
        )
    }

    // MARK: - KernelInlining: head fusion

    /// `Saturation → Sharpen` activates KernelInlining: the optimiser
    /// drops the Saturation node and stamps `Node.inlinedBodyBefore
    /// Sample` on Sharpen so the source-tap kernel applies Saturation
    /// to every sampled pixel.
    ///
    /// On a solid source Sharpen is identity (all four neighbours
    /// equal the centre, Laplacian is zero), so the fused output must
    /// equal the post-Saturation pixel. Compare against the same
    /// chain with `.none` — which runs Saturation and Sharpen as two
    /// independent dispatches through `rgba16Float` intermediates —
    /// and require the two outputs to agree within the half-float
    /// rounding floor accumulated across the two intermediate writes.
    ///
    /// If the codegen and `bindUniforms` disagree on the head's
    /// buffer slot, the fused kernel would read uninitialised /
    /// stale bytes for `uHead.saturation`, producing a colour that
    /// diverges from the `.none` baseline by more than the rounding
    /// margin.
    func testKernelInliningHeadFusionMatchesUnfusedDispatch() throws {
        let source = try makeSolidTexture(
            width: 16, height: 16,
            red: 0.4, green: 0.3, blue: 0.2
        )
        let steps: [AnyFilter] = [
            .single(SaturationFilter(saturation: 1.4)),
            .single(SharpenFilter(amount: 1.0, stepPixels: 1)),
        ]

        let fullPx = try runChainAndReadCenter(
            source: source, steps: steps, optimization: .full
        )
        let nonePx = try runChainAndReadCenter(
            source: source, steps: steps, optimization: .none
        )

        // Tolerance derivation:
        // - Float16 quantisation across two intermediate writes (.none
        //   path): ~0.4% per write × 2 ≈ 0.008.
        // - Source-tap fused path skips one intermediate, so its own
        //   error is half the .none path's. Pad to 0.01 for safety.
        XCTAssertEqual(fullPx.r, nonePx.r, accuracy: 0.01,
                       "head-fused R diverges from per-pass baseline → likely uHead slot mismatch")
        XCTAssertEqual(fullPx.g, nonePx.g, accuracy: 0.01,
                       "head-fused G diverges from per-pass baseline → likely uHead slot mismatch")
        XCTAssertEqual(fullPx.b, nonePx.b, accuracy: 0.01,
                       "head-fused B diverges from per-pass baseline → likely uHead slot mismatch")
    }

    // MARK: - TailSink: tail fusion

    /// `Sharpen → Saturation` activates TailSink: Saturation is
    /// captured in `Node.tailSinkedBody` on Sharpen so the source-tap
    /// kernel runs Saturation between Sharpen's body call and
    /// `output.write`.
    ///
    /// The same logic as the head-fusion test: compare against the
    /// `.none` baseline. If the tail's buffer slot disagrees between
    /// codegen and `bindUniforms`, the fused kernel reads the wrong
    /// uniforms for `uTail.saturation` and the colour diverges.
    func testTailSinkTailFusionMatchesUnfusedDispatch() throws {
        let source = try makeSolidTexture(
            width: 16, height: 16,
            red: 0.4, green: 0.3, blue: 0.2
        )
        let steps: [AnyFilter] = [
            .single(SharpenFilter(amount: 1.0, stepPixels: 1)),
            .single(SaturationFilter(saturation: 1.4)),
        ]

        let fullPx = try runChainAndReadCenter(
            source: source, steps: steps, optimization: .full
        )
        let nonePx = try runChainAndReadCenter(
            source: source, steps: steps, optimization: .none
        )

        XCTAssertEqual(fullPx.r, nonePx.r, accuracy: 0.01,
                       "tail-sunk R diverges from per-pass baseline → likely uTail slot mismatch")
        XCTAssertEqual(fullPx.g, nonePx.g, accuracy: 0.01,
                       "tail-sunk G diverges from per-pass baseline → likely uTail slot mismatch")
        XCTAssertEqual(fullPx.b, nonePx.b, accuracy: 0.01,
                       "tail-sunk B diverges from per-pass baseline → likely uTail slot mismatch")
    }

    // MARK: - Combined head + tail

    /// Both KernelInlining and TailSink fire on a `Vibrance → Sharpen
    /// → Saturation` chain: Vibrance becomes the head-fused
    /// `inlinedBodyBeforeSample`, Saturation becomes the tail-fused
    /// `tailSinkedBody`. The fused Sharpen kernel binds three uniform
    /// buffers — `u0` (Sharpen), `uHead` (Vibrance), `uTail`
    /// (Saturation) — each carrying distinct values.
    ///
    /// This test is the strongest guard against slot drift: both
    /// `uHead` and `uTail` must land at the right slots. Swapping
    /// either with the other (or with `u0`) produces a clearly wrong
    /// colour on a saturated input.
    func testHeadAndTailFusionCombinedMatchesUnfusedDispatch() throws {
        let source = try makeSolidTexture(
            width: 16, height: 16,
            red: 0.6, green: 0.3, blue: 0.2   // off-grey so Vibrance + Saturation both bite
        )
        let steps: [AnyFilter] = [
            .single(VibranceFilter(vibrance: 0.5)),
            .single(SharpenFilter(amount: 1.0, stepPixels: 1)),
            .single(SaturationFilter(saturation: 1.3)),
        ]

        let fullPx = try runChainAndReadCenter(
            source: source, steps: steps, optimization: .full
        )
        let nonePx = try runChainAndReadCenter(
            source: source, steps: steps, optimization: .none
        )

        // Three filters → three intermediate writes on the .none path
        // → ~0.012 cumulative half-float error. Pad to 0.015.
        XCTAssertEqual(fullPx.r, nonePx.r, accuracy: 0.015,
                       "head+tail R diverges → uHead or uTail slot drifted vs codegen")
        XCTAssertEqual(fullPx.g, nonePx.g, accuracy: 0.015,
                       "head+tail G diverges → uHead or uTail slot drifted vs codegen")
        XCTAssertEqual(fullPx.b, nonePx.b, accuracy: 0.015,
                       "head+tail B diverges → uHead or uTail slot drifted vs codegen")
    }

    // MARK: - Fixtures

    private func runChainAndReadCenter(
        source: MTLTexture,
        steps: [AnyFilter],
        optimization: PipelineOptimization
    ) throws -> (r: Float, g: Float, b: Float, a: Float) {
        let pipeline = Pipeline(
            optimization: optimization,
            intermediatePixelFormat: .rgba16Float,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: texturePool,
            commandBufferPool: commandBufferPool
        )
        let output = try pipeline.processSync(input: .texture(source), steps: steps)
        return try readCenterPixel(output)
    }

    private func makeSolidTexture(
        width: Int, height: Int,
        red: Float, green: Float = 0.0, blue: Float = 0.0, alpha: Float = 1.0
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let hr = Float16(red).bitPattern
        let hg = Float16(green).bitPattern
        let hb = Float16(blue).bitPattern
        let ha = Float16(alpha).bitPattern
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = hr
            pixels[i * 4 + 1] = hg
            pixels[i * 4 + 2] = hb
            pixels[i * 4 + 3] = ha
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

    /// Read the centre pixel by blitting `texture` to a shared
    /// staging texture and decoding the 4×Float16 layout. Centre
    /// (not corner) avoids any edge-clamp asymmetry from Sharpen's
    /// neighbourhood reads.
    private func readCenterPixel(
        _ texture: MTLTexture
    ) throws -> (r: Float, g: Float, b: Float, a: Float) {
        guard let staging = device.metalDevice.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width, height: texture.height,
                mipmapped: false
            )
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            return d
        }()) else {
            throw XCTSkip("Unable to allocate staging texture")
        }
        let cb = try XCTUnwrap(device.metalDevice.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: staging, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var raw = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        let cx = texture.width / 2
        let cy = texture.height / 2
        let base = (cy * texture.width + cx) * 4
        return (
            r: Float(Float16(bitPattern: raw[base + 0])),
            g: Float(Float16(bitPattern: raw[base + 1])),
            b: Float(Float16(bitPattern: raw[base + 2])),
            a: Float(Float16(bitPattern: raw[base + 3]))
        )
    }
}
