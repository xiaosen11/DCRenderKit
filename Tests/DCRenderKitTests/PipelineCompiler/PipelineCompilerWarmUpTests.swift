//
//  PipelineCompilerWarmUpTests.swift
//  DCRenderKitTests
//
//  Phase 5 step 5.6 coverage for the SDK's warm-up API. Verifies:
//
//    1. `PipelineCompilerWarmUp.preheat(...)` populates the shared
//       uber-kernel cache for every combination the caller
//       specifies.
//    2. A subsequent `Pipeline.outputSync()` with the same chain
//       compiles zero new PSOs — the warm-up did the work.
//    3. Combinations that can't be lowered to a compiler-path graph
//       (multi-pass filters, third-party `.unsupported` filters)
//       are silently skipped, not errored.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class PipelineCompilerWarmUpTests: XCTestCase {

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

    // MARK: - Tests

    /// Preheating a three-filter pixel-local chain should compile
    /// exactly one uber kernel (the `VerticalFusion`-produced
    /// cluster) into the shared cache. A subsequent
    /// `Pipeline.outputSync()` with the same chain should be a pure
    /// cache hit — zero additional PSOs compiled.
    func testPreheatCompilesClusterUberKernelAndSubsequentDispatchIsCached() async throws {
        let combination: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.2)),
        ]

        try await PipelineCompilerWarmUp.preheat(combinations: [combination])
        let afterPreheat = UberKernelCache.shared.cachedPipelineCount
        XCTAssertEqual(
            afterPreheat, 1,
            "Warm-up should compile exactly the fused cluster's uber kernel; got \(afterPreheat)."
        )

        // Now run a Pipeline with the same chain. No new PSOs.
        let source = try makeSolidTexture(width: 16, height: 16, red: 0.5)
        let pipeline = makePipeline()
        _ = try pipeline.processSync(
            input: .texture(source),
            steps: combination
        )
        XCTAssertEqual(
            UberKernelCache.shared.cachedPipelineCount, afterPreheat,
            "Dispatch after warm-up must be a cache hit — no new PSOs."
        )
    }

    /// Preheating a chain that mixes multiple distinct-shape filters
    /// compiles one uber kernel per node that survives the optimiser.
    /// `[Exposure, LUT3D, Saturation]` has three different signature
    /// shapes so `VerticalFusion` leaves them separate ⇒ three
    /// uber kernels.
    func testPreheatMultiShapeChainCompilesPerNode() async throws {
        let identityCube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let cubeData = identityCube.withUnsafeBufferPointer { Data(buffer: $0) }

        let combination: [AnyFilter] = [
            .single(ExposureFilter(exposure: 5)),
            .single(try LUT3DFilter(cubeData: cubeData, dimension: 2, intensity: 1.0)),
            .single(SaturationFilter(saturation: 1.1)),
        ]

        try await PipelineCompilerWarmUp.preheat(combinations: [combination])
        XCTAssertEqual(
            UberKernelCache.shared.cachedPipelineCount, 3,
            "Three distinct-shape pixel-local filters must compile three uber kernels."
        )
    }

    /// A chain containing a multi-pass filter can't be lowered to a
    /// compiler-path graph today — `Lowering` emits `.nativeCompute`
    /// nodes for each pass and `MetalSourceBuilder` doesn't codegen
    /// those. `preheat` should skip the combination silently, not
    /// throw.
    func testPreheatSilentlySkipsUnlowerableCombination() async throws {
        let combination: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .multi(HighlightShadowFilter(highlights: 20)),
            .single(SaturationFilter(saturation: 1.1)),
        ]

        try await PipelineCompilerWarmUp.preheat(combinations: [combination])

        // Exposure + Saturation still compile (they're eligible
        // single-pass filters). HighlightShadow's `.nativeCompute`
        // passes are skipped.
        let count = UberKernelCache.shared.cachedPipelineCount
        XCTAssertEqual(
            count, 2,
            "Warm-up should still compile the eligible single-pass filters' uber kernels around the skipped multi-pass filter; got \(count)."
        )
    }

    /// Warming an empty list of combinations is a no-op that returns
    /// without throwing.
    func testPreheatNoopOnEmptyList() async throws {
        try await PipelineCompilerWarmUp.preheat(combinations: [])
        XCTAssertEqual(UberKernelCache.shared.cachedPipelineCount, 0)
    }

    // MARK: - Fixtures

    private func makePipeline() -> Pipeline {
        Pipeline(
            optimization: .full,
            intermediatePixelFormat: .rgba16Float,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: texturePool,
            commandBufferPool: commandBufferPool
        )
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
}
