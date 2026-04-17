//
//  MultiPassFilterTests.swift
//  DCRenderKitTests
//
//  Tests for Batch 3 multi-pass filters:
//  HighlightShadow / Clarity / SoftGlow.
//

import XCTest
@testable import DCRenderKit
import Metal

final class MultiPassFilterTests: XCTestCase {

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

    // MARK: - HighlightShadow pass-graph shape

    func testHighlightShadowIdentityProducesEmptyGraph() {
        let f = HighlightShadowFilter(highlights: 0, shadows: 0)
        let info = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        XCTAssertTrue(f.passes(input: info).isEmpty)
    }

    func testHighlightShadowActiveGraphHasFivePasses() {
        let f = HighlightShadowFilter(highlights: 50, shadows: 25)
        let info = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        let passes = f.passes(input: info)
        XCTAssertEqual(passes.count, 5)
        XCTAssertEqual(passes[0].name, "downsample")
        XCTAssertEqual(passes.last?.isFinal, true)
    }

    // MARK: - Clarity pass-graph shape

    func testClarityIdentityProducesEmptyGraph() {
        let f = ClarityFilter(intensity: 0)
        let info = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        XCTAssertTrue(f.passes(input: info).isEmpty)
    }

    func testClarityActiveGraphHasFivePasses() {
        let f = ClarityFilter(intensity: 40)
        let info = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        XCTAssertEqual(f.passes(input: info).count, 5)
    }

    // MARK: - SoftGlow pass-graph shape + dynamic pyramid

    func testSoftGlowIdentityAtZeroStrength() {
        let f = SoftGlowFilter(strength: 0, threshold: 50, bloomRadius: 50)
        let info = TextureInfo(width: 1080, height: 1920, pixelFormat: .rgba16Float)
        XCTAssertTrue(f.passes(input: info).isEmpty)
    }

    func testSoftGlowPyramidDepthAt1080p() {
        // shortSide=1080 → log2(1080/135)=log2(8)=3 levels → 7 passes total.
        let f = SoftGlowFilter(strength: 50)
        let info = TextureInfo(width: 1920, height: 1080, pixelFormat: .rgba16Float)
        let passes = f.passes(input: info)
        XCTAssertEqual(passes.count, 7, "3 levels × 2 + 1 final = 7 passes at 1080p")
    }

    func testSoftGlowPyramidDepthAt4K() {
        // shortSide=2160 → log2(2160/135)=log2(16)=4 levels → 9 passes.
        let f = SoftGlowFilter(strength: 50)
        let info = TextureInfo(width: 3840, height: 2160, pixelFormat: .rgba16Float)
        XCTAssertEqual(f.passes(input: info).count, 9)
    }

    func testSoftGlowPyramidFloorAtSmallResolution() {
        // shortSide=64 → log2(64/135) ≈ -1 → clamp to min 3 levels → 7 passes.
        let f = SoftGlowFilter(strength: 50)
        let info = TextureInfo(width: 64, height: 128, pixelFormat: .rgba16Float)
        XCTAssertEqual(f.passes(input: info).count, 7)
    }

    // MARK: - End-to-end execution

    func testHighlightShadowEndToEnd() throws {
        let source = try makeMultipassSource(red: 0.5, green: 0.5, blue: 0.5, width: 64, height: 64)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(HighlightShadowFilter(highlights: 30, shadows: -20))]
        )
        let output = try pipeline.outputSync()
        let pixels = try readMultipassTexture(output)

        // All pixels must be finite and in [0, 1].
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                XCTAssertGreaterThanOrEqual(p.r, -1e-3)
                XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3)
            }
        }
    }

    func testHighlightShadowIdentityPassesSourceThrough() throws {
        let source = try makeMultipassSource(red: 0.42, green: 0.42, blue: 0.42, width: 16, height: 16)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(HighlightShadowFilter(highlights: 0, shadows: 0))]
        )
        let output = try pipeline.outputSync()
        // Empty pass graph should short-circuit to the source texture.
        XCTAssertTrue(output === source)
    }

    func testClarityEndToEnd() throws {
        let source = try makeRampMultipassSource()
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(ClarityFilter(intensity: 50))]
        )
        let output = try pipeline.outputSync()
        let pixels = try readMultipassTexture(output)
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                XCTAssertGreaterThanOrEqual(p.r, -1e-3)
                XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3)
            }
        }
    }

    func testClarityNegativeIntensityStaysInGamut() throws {
        let source = try makeRampMultipassSource()
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(ClarityFilter(intensity: -100))]
        )
        let output = try pipeline.outputSync()
        let pixels = try readMultipassTexture(output)
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                XCTAssertGreaterThanOrEqual(p.r, -1e-3)
                XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3)
            }
        }
    }

    func testSoftGlowEndToEnd() throws {
        let source = try makeMultipassSource(
            red: 0.9, green: 0.9, blue: 0.9, width: 64, height: 64
        )
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(SoftGlowFilter(strength: 80, threshold: 20, bloomRadius: 50))]
        )
        let output = try pipeline.outputSync()
        let pixels = try readMultipassTexture(output)

        // A bright source under SoftGlow should stay in-gamut.
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                XCTAssertGreaterThanOrEqual(p.r, -1e-3)
                XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3)
            }
        }
    }

    func testSoftGlowStrengthZeroIsIdentity() throws {
        let source = try makeMultipassSource(red: 0.3, green: 0.5, blue: 0.7, width: 32, height: 32)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(SoftGlowFilter(strength: 0))]
        )
        let output = try pipeline.outputSync()
        XCTAssertTrue(output === source)
    }

    // MARK: - Fuse groups

    func testMultiPassFiltersDeclareNoFuseGroup() {
        XCTAssertNil(HighlightShadowFilter.fuseGroup)
        XCTAssertNil(ClarityFilter.fuseGroup)
        XCTAssertNil(SoftGlowFilter.fuseGroup)
    }

    // MARK: - Intermediate-format contract (P0 regression)
    //
    // The three tests below lock down the contract that broke on-device in
    // DCRDemo: `Pipeline.intermediatePixelFormat` must flow into every
    // intermediate texture the multi-pass executor allocates, regardless
    // of the *source* texture's native format. The bug was that
    // `executeMultiPass` never forwarded the format; the executor fell
    // back to `source.pixelFormat`, which for a camera feed is
    // `bgra8Unorm`. That silently truncated HighlightShadow's ratio
    // values > 1.0, SoftGlow's bloom accumulation, and Clarity's
    // residual terms — producing over-exposure, loss of gradient, and
    // per-frame jitter.

    func testMultiPassOutputUsesIntermediateFormatRegardlessOfSourceFormat() throws {
        let source = try makeBgra8UnormSource(
            r: 0.5, g: 0.5, b: 0.5, width: 32, height: 32
        )
        XCTAssertEqual(source.pixelFormat, .bgra8Unorm)

        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(HighlightShadowFilter(highlights: 50, shadows: -20))]
        )
        let output = try pipeline.outputSync()

        // Multi-pass filter output must inherit the pipeline's intermediate
        // format (rgba16Float here), NOT the source texture's format.
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
    }

    func testHighlightShadowPositiveEffectiveOnBgra8UnormSource() throws {
        // The on-device symptom: with a bgra8Unorm camera frame, positive
        // `highlights` produced no visible effect. Root cause: the
        // multi-pass `ratio` intermediate was allocated as bgra8Unorm
        // → ratios > 1.0 clamped back to 1.0 → kernel applied 1× (identity).
        //
        // HS kernel formula: ratio = 1 + highlights·h_weight·0.35.
        // For highlights=+100 and a baseLuma of 0.7 the ratio is ≈1.295
        // → output ≈ 0.7·1.295 ≈ 0.907 (well below the 1.0 clamp).
        // Picking 0.7 (not 0.9) keeps us out of the saturation ceiling
        // so the test measures the filter's actual effect, not the clamp.
        let source = try makeBgra8UnormSource(
            r: 0.7, g: 0.7, b: 0.7, width: 32, height: 32
        )

        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(HighlightShadowFilter(highlights: 100, shadows: 0))]
        )
        let output = try pipeline.outputSync()
        let pixels = try readMultipassTexture(output)

        let center = pixels[16][16]
        XCTAssertGreaterThan(
            center.r, 0.82,
            "HighlightShadow(+100,0) on 0.7 bgra8Unorm source must brighten visibly; got r=\(center.r)"
        )
        XCTAssertTrue(center.r.isFinite)
        XCTAssertLessThanOrEqual(center.r, 1.0 + 1e-3)
    }

    func testSoftGlowOutputIsNotSaturatedAt1OnBgra8UnormSource() throws {
        // The on-device symptom: SoftGlow produced a uniformly over-exposed
        // image with no layered gradient. Root cause: bloom pyramid
        // intermediates in bgra8Unorm truncated every additive step at 1.0,
        // so by the time the screen blend ran, every pixel was saturated.
        //
        // A gradient source with the fixed precision chain must retain a
        // visible dynamic range after SoftGlow.
        let source = try makeBgra8UnormGradientSource(width: 64, height: 8)

        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.multi(SoftGlowFilter(strength: 60, threshold: 30, bloomRadius: 50))]
        )
        let output = try pipeline.outputSync()
        let pixels = try readMultipassTexture(output)

        var minR: Float = .infinity
        var maxR: Float = -.infinity
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                minR = min(minR, p.r)
                maxR = max(maxR, p.r)
            }
        }

        // Fixed path: gradient survives through bloom → some dynamic
        // range preserved. Bugged path: everything saturates at 1.0
        // → maxR - minR ≈ 0.
        XCTAssertGreaterThan(
            maxR - minR, 0.15,
            "SoftGlow output must preserve gradient; got min=\(minR) max=\(maxR)"
        )
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
}

// MARK: - Private utilities

private struct MPPixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeMultipassSource(
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

/// Simulates a camera feed: `bgra8Unorm`, the format `CVMetalTextureCache`
/// hands out for 32BGRA CVPixelBuffers. Byte order is B, G, R, A.
private func makeBgra8UnormSource(
    r: Float, g: Float, b: Float, alpha: Float = 1.0,
    width: Int, height: Int
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    let bb = UInt8((b * 255.0).rounded().clamped(to: 0 ... 255))
    let gb = UInt8((g * 255.0).rounded().clamped(to: 0 ... 255))
    let rb = UInt8((r * 255.0).rounded().clamped(to: 0 ... 255))
    let ab = UInt8((alpha * 255.0).rounded().clamped(to: 0 ... 255))

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height) {
        pixels[i * 4 + 0] = bb
        pixels[i * 4 + 1] = gb
        pixels[i * 4 + 2] = rb
        pixels[i * 4 + 3] = ab
    }
    pixels.withUnsafeBytes { bytes in
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: width * 4
        )
    }
    return tex
}

/// A bgra8Unorm horizontal luma ramp from 0.2 to 0.8 — exercises bloom /
/// smooth pipelines on dynamic-range content.
private func makeBgra8UnormGradientSource(width: Int, height: Int) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let t = Float(x) / Float(max(width - 1, 1))
            let v = 0.2 + 0.6 * t
            let vb = UInt8((v * 255.0).rounded().clamped(to: 0 ... 255))
            let off = (y * width + x) * 4
            pixels[off + 0] = vb
            pixels[off + 1] = vb
            pixels[off + 2] = vb
            pixels[off + 3] = 255
        }
    }
    pixels.withUnsafeBytes { bytes in
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: width * 4
        )
    }
    return tex
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// A 64×64 horizontal luma ramp — exercises edge-preserving filters at
/// interior transitions.
private func makeRampMultipassSource() throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let width = 64
    let height = 64
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
            let v = Float(x) / Float(width - 1)
            let h = Float16(v).bitPattern
            let off = (y * width + x) * 4
            pixels[off + 0] = h
            pixels[off + 1] = h
            pixels[off + 2] = h
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

private func readMultipassTexture(_ texture: MTLTexture) throws -> [[MPPixel]] {
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
    var result: [[MPPixel]] = []
    for y in 0..<height {
        var row: [MPPixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(MPPixel(
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
