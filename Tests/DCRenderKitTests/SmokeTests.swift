//
//  SmokeTests.swift
//  DCRenderKitTests
//
//  Round 12: end-to-end smoke tests that stack realistic filter chains
//  and verify the full SDK surface works cohesively. These tests cover
//  cross-filter interactions that per-filter unit tests miss by design.
//

import XCTest
@testable import DCRenderKit
import Metal

final class SmokeTests: XCTestCase {

    var device: Device!
    var psoCache: PipelineStateCache!
    var uniformPool: UniformBufferPool!
    var samplerCache: SamplerCache!
    var texturePool: TexturePool!
    var commandBufferPool: CommandBufferPool!
    var textureLoader: TextureLoader!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 3, bufferSize: 256)
        samplerCache = SamplerCache(device: d)
        texturePool = TexturePool(device: d, maxBytes: 128 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)
        ShaderLibrary.shared.unregisterAll()
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        commandBufferPool = nil
        texturePool = nil
        samplerCache = nil
        uniformPool = nil
        psoCache = nil
        textureLoader = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Version metadata

    func testSDKVersionIsWellFormed() {
        XCTAssertFalse(DCRenderKit.version.isEmpty)
        XCTAssertFalse(DCRenderKit.channel.isEmpty)
    }

    // MARK: - Realistic DigiCam-style edit chain

    func testRealisticEditChainProducesInGamutOutput() throws {
        // Mirror the order DigiCam's EditParameters.toHarbethFilters emits:
        // tone → colour grading → clarity → sharpen → film grain → LUT.
        // Every filter set mid-strength so interactions are exercised.
        let source = try makeSmokeRamp(width: 128, height: 128)
        let lut = try LUT3DFilter(
            cubeData: identityCubeData(dimension: 5),
            dimension: 5,
            intensity: 1.0,
            device: device
        )

        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 20)),
                .single(ContrastFilter(contrast: 15, lumaMean: 0.5)),
                .single(WhitesFilter(whites: 30, lumaMean: 0.5)),
                .single(BlacksFilter(blacks: -20)),
                .single(WhiteBalanceFilter(temperature: 5500, tint: 10)),
                .single(VibranceFilter(vibrance: 0.3)),
                .single(SaturationFilter(saturation: 1.1)),
                .multi(HighlightShadowFilter(highlights: -20, shadows: 15)),
                .multi(ClarityFilter(intensity: 25)),
                .single(SharpenFilter(amount: 40, step: 2)),
                .single(FilmGrainFilter(density: 0.3, roughness: 0.4, chromaticity: 0.2, grainSize: 3)),
                .single(lut),
            ]
        )

        let output = try pipeline.outputSync()
        assertInGamut(output)
    }

    // MARK: - Multi-pass filters stacked

    func testStackedMultiPassFiltersChainCleanly() throws {
        let source = try makeSmokeRamp(width: 128, height: 128)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .multi(HighlightShadowFilter(highlights: 30, shadows: -15)),
                .multi(ClarityFilter(intensity: 40)),
                .multi(SoftGlowFilter(strength: 50, threshold: 40, bloomRadius: 30)),
            ]
        )
        let output = try pipeline.outputSync()
        assertInGamut(output)
    }

    // MARK: - PortraitBlur + foreground sharpen

    func testMaskDrivenBlurThenSharpen() throws {
        let source = try makeSmokeRamp(width: 128, height: 128)

        // Half-subject / half-background mask.
        let mask = try makeHalfMask(width: 128, height: 128)

        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .multi(PortraitBlurFilter(strength: 100, maskTexture: mask)),
                .single(SharpenFilter(amount: 40, step: 2)),
            ]
        )
        let output = try pipeline.outputSync()
        assertInGamut(output)
    }

    // MARK: - DateStamp-style NormalBlend at chain tail

    func testEditChainWithNormalBlendTail() throws {
        let source = try makeSmokeSolid(
            red: 0.4, green: 0.4, blue: 0.4,
            width: 64, height: 64
        )
        // Premultiplied-alpha watermark: mostly transparent, one opaque pixel.
        let watermark = try makeSmokeSolid(
            red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0,
            width: 64, height: 64
        )

        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(NormalBlendFilter(overlay: watermark, intensity: 0.5)),
            ]
        )
        let output = try pipeline.outputSync()
        assertInGamut(output)

        // Expect the 50% blend with full-white watermark to push the
        // pixel well above the original 0.4.
        let pixels = try readSmokeTexture(output)
        XCTAssertGreaterThan(pixels[32][32].r, 0.6)
    }

    // MARK: - Async / sync equivalence

    func testAsyncAndSyncProduceEquivalentOutputs() async throws {
        let source = try makeSmokeSolid(
            red: 0.5, green: 0.5, blue: 0.5,
            width: 32, height: 32
        )
        let stepsSync: [AnyFilter] = [
            .single(ExposureFilter(exposure: 15)),
            .single(SaturationFilter(saturation: 1.2)),
        ]
        let stepsAsync: [AnyFilter] = stepsSync  // identical

        let syncPipeline = makePipeline(input: .texture(source), steps: stepsSync)
        let syncOutput = try syncPipeline.outputSync()
        let syncPixels = try readSmokeTexture(syncOutput)

        let asyncPipeline = makePipeline(input: .texture(source), steps: stepsAsync)
        let asyncOutput = try await asyncPipeline.output()
        let asyncPixels = try readSmokeTexture(asyncOutput)

        // Allow a tiny drift for GPU scheduling; half-precision drift
        // should be well below 0.005.
        XCTAssertEqual(
            syncPixels[16][16].r, asyncPixels[16][16].r, accuracy: 0.005
        )
    }

    // MARK: - Pool reuse: many runs don't exhaust resources

    func testRepeatedPipelineRunsReleasePoolTextures() throws {
        let source = try makeSmokeSolid(
            red: 0.5, green: 0.5, blue: 0.5,
            width: 64, height: 64
        )

        // Stack multi-pass + single-pass so intermediate textures flow
        // through MultiPassExecutor's lifetime analysis and TexturePool
        // recycling. Run many times to catch leaks.
        for iteration in 0..<20 {
            let pipeline = makePipeline(
                input: .texture(source),
                steps: [
                    .multi(HighlightShadowFilter(highlights: 20, shadows: -10)),
                    .single(SaturationFilter(saturation: 1.1)),
                    .multi(SoftGlowFilter(strength: 30)),
                ]
            )
            let output = try pipeline.outputSync()
            XCTAssertEqual(output.width, 64, "iteration \(iteration)")
            XCTAssertEqual(output.height, 64, "iteration \(iteration)")
        }
    }

    // MARK: - Empty chain passes source through

    func testEmptyChainIsIdentity() throws {
        let source = try makeSmokeSolid(
            red: 0.42, green: 0.42, blue: 0.42,
            width: 16, height: 16
        )
        let pipeline = makePipeline(input: .texture(source), steps: [])
        let output = try pipeline.outputSync()
        XCTAssertTrue(output === source)
    }

    // MARK: - Identity-only chain (all strengths at zero)

    func testAllZeroStrengthChainIsEssentiallyIdentity() throws {
        let source = try makeSmokeSolid(
            red: 0.3, green: 0.6, blue: 0.9,
            width: 16, height: 16
        )
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 0)),
                .single(ContrastFilter(contrast: 0, lumaMean: 0.5)),
                .single(WhitesFilter(whites: 0, lumaMean: 0.5)),
                .single(BlacksFilter(blacks: 0)),
                .single(VibranceFilter(vibrance: 0)),
                .single(SaturationFilter(saturation: 1)),
                .single(SharpenFilter(amount: 0)),
                .single(FilmGrainFilter(density: 0)),
                .multi(HighlightShadowFilter(highlights: 0, shadows: 0)),
                .multi(ClarityFilter(intensity: 0)),
                .multi(SoftGlowFilter(strength: 0)),
            ]
        )
        let output = try pipeline.outputSync()
        let p = try readSmokeTexture(output)[8][8]
        XCTAssertEqual(p.r, 0.3, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.6, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.9, accuracy: 0.02)
    }

    // MARK: - FuseGroup contracts

    func testAllToneAdjustmentFiltersShareFuseGroup() {
        XCTAssertEqual(ExposureFilter.fuseGroup, .toneAdjustment)
        XCTAssertEqual(ContrastFilter.fuseGroup, .toneAdjustment)
        XCTAssertEqual(WhitesFilter.fuseGroup, .toneAdjustment)
        XCTAssertEqual(BlacksFilter.fuseGroup, .toneAdjustment)
    }

    func testAllColorGradingFiltersShareFuseGroup() {
        XCTAssertEqual(WhiteBalanceFilter.fuseGroup, .colorGrading)
        XCTAssertEqual(VibranceFilter.fuseGroup, .colorGrading)
        XCTAssertEqual(SaturationFilter.fuseGroup, .colorGrading)
    }

    // MARK: - Helpers

    private func makePipeline(
        input: PipelineInput,
        steps: [AnyFilter]
    ) -> Pipeline {
        Pipeline(
            input: input,
            steps: steps,
            optimizer: FilterGraphOptimizer(),
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

    /// Verify output is finite and within a tolerant gamut band.
    ///
    /// Several filters (FilmGrain's symmetric SoftLight, Vibrance's
    /// `mix` extrapolation with negative amt, etc.) intentionally let
    /// intermediate values overshoot `[0, 1]` — the SDK is HDR-capable,
    /// and clamping inside every filter would cripple chainable
    /// workflows. Final rendering to an 8-bit surface should clamp at
    /// the last stage or apply a tonemap; chains that stay inside
    /// `rgba16Float` can carry the overshoot.
    ///
    /// Gamut tolerance of ±0.02 absorbs Float16 ULP noise near 1 (~0.001)
    /// plus the intentional overshoot from HDR-aware filters.
    private func assertInGamut(
        _ texture: MTLTexture,
        file: StaticString = #file, line: UInt = #line
    ) {
        do {
            let pixels = try readSmokeTexture(texture)
            for row in pixels {
                for p in row {
                    XCTAssertTrue(p.r.isFinite, "R not finite", file: file, line: line)
                    XCTAssertTrue(p.g.isFinite, "G not finite", file: file, line: line)
                    XCTAssertTrue(p.b.isFinite, "B not finite", file: file, line: line)
                    XCTAssertGreaterThanOrEqual(p.r, -0.02, file: file, line: line)
                    XCTAssertGreaterThanOrEqual(p.g, -0.02, file: file, line: line)
                    XCTAssertGreaterThanOrEqual(p.b, -0.02, file: file, line: line)
                    XCTAssertLessThanOrEqual(p.r, 1.02, file: file, line: line)
                    XCTAssertLessThanOrEqual(p.g, 1.02, file: file, line: line)
                    XCTAssertLessThanOrEqual(p.b, 1.02, file: file, line: line)
                }
            }
        } catch {
            XCTFail("Gamut check failed: \(error)", file: file, line: line)
        }
    }

    private func makeHalfMask(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        // Left half subject (1), right half background (0).
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = x < width / 2 ? 255 : 0
            }
        }
        bytes.withUnsafeBufferPointer { ptr in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: width
            )
        }
        return tex
    }

    private func identityCubeData(dimension: Int) -> Data {
        let maxIdx = Float(dimension - 1)
        var rgba: [Float] = []
        rgba.reserveCapacity(dimension * dimension * dimension * 4)
        for k in 0..<dimension {
            for j in 0..<dimension {
                for i in 0..<dimension {
                    rgba.append(Float(i) / maxIdx)
                    rgba.append(Float(j) / maxIdx)
                    rgba.append(Float(k) / maxIdx)
                    rgba.append(1.0)
                }
            }
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Private utilities

private struct SmokePixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeSmokeSolid(
    red: Float, green: Float, blue: Float, alpha: Float = 1.0,
    width: Int, height: Int
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let hr = Float16(red).bitPattern
    let hg = Float16(green).bitPattern
    let hb = Float16(blue).bitPattern
    let ha = Float16(alpha).bitPattern
    for i in 0..<(width * height) {
        pixels[i * 4 + 0] = hr
        pixels[i * 4 + 1] = hg
        pixels[i * 4 + 2] = hb
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

private func makeSmokeRamp(width: Int, height: Int) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let ha = Float16(1.0).bitPattern
    for y in 0..<height {
        for x in 0..<width {
            let r = Float(x) / Float(width - 1)
            let g = Float(y) / Float(height - 1)
            let b = 0.5 * (r + g)
            let off = (y * width + x) * 4
            pixels[off + 0] = Float16(r).bitPattern
            pixels[off + 1] = Float16(g).bitPattern
            pixels[off + 2] = Float16(b).bitPattern
            pixels[off + 3] = ha
        }
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

private func readSmokeTexture(_ texture: MTLTexture) throws -> [[SmokePixel]] {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let width = texture.width
    let height = texture.height
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: texture.pixelFormat,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let staging = try XCTUnwrap(device.makeTexture(descriptor: desc))

    let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    try BlitDispatcher.copy(source: texture, destination: staging, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var raw = [UInt16](repeating: 0, count: width * height * 4)
    raw.withUnsafeMutableBytes { bytes in
        staging.getBytes(
            bytes.baseAddress!,
            bytesPerRow: width * 8,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    var result: [[SmokePixel]] = []
    for y in 0..<height {
        var row: [SmokePixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(SmokePixel(
                r: Float(Float16(bitPattern: raw[offset + 0])),
                g: Float(Float16(bitPattern: raw[offset + 1])),
                b: Float(Float16(bitPattern: raw[offset + 2])),
                a: Float(Float16(bitPattern: raw[offset + 3]))
            ))
        }
        result.append(row)
    }
    return result
}
