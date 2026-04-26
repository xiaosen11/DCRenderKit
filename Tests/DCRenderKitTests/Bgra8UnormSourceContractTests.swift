//
//  Bgra8UnormSourceContractTests.swift
//  DCRenderKitTests
//
//  Coverage for the camera-feed input path: every kind of filter must
//  produce correct output when the source texture is `bgra8Unorm` (the
//  format that CVMetalTextureCache hands out for 32BGRA CVPixelBuffers).
//
//  Why a dedicated file: the original test suite used rgba16Float sources
//  exclusively, which accidentally masked the P0 precision-chain bug —
//  multi-pass filters were happy because `MultiPassExecutor.sourceInfo`
//  inherited the rgba16Float format from the source texture, not from
//  `Pipeline.intermediatePixelFormat`. The real camera path (bgra8Unorm
//  source) was untested. These tests close that gap by running every
//  filter class against a bgra8Unorm source and asserting:
//    1. Output pixel format matches `intermediatePixelFormat` (contract)
//    2. Output is finite and in gamut (sanity)
//    3. Filter actually has an effect (not degraded to identity by
//       silent precision loss)
//
//  Compare: `.claude/rules/testing.md` §1.2 (source data must cover
//  every production code path).
//

import XCTest
@testable import DCRenderKit
import Metal

final class Bgra8UnormSourceContractTests: XCTestCase {

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
        texturePool = TexturePool(device: d, maxBytes: 64 * 1024 * 1024)
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

    // MARK: - Single-pass filter contracts

    func testExposureOnBgra8UnormSourceProducesFloatOutput() throws {
        let source = try makeBgra8UnormUniform(r: 0.3, g: 0.3, b: 0.3, width: 16, height: 16)
        XCTAssertEqual(source.pixelFormat, .bgra8Unorm)

        // Explicit `.perceptual` so this contract test's numerical
        // derivation (ported from testExposurePositiveFullSliderOnShadow)
        // stays valid regardless of the SDK default.
        let output = try runPipeline(
            source: source,
            steps: [.single(ExposureFilter(exposure: 100, colorSpace: .perceptual))]
        )
        XCTAssertEqual(
            output.pixelFormat, .rgba16Float,
            "Single-pass output must be rgba16Float regardless of source format"
        )

        // Perceptual-branch derivation: output ≈ 0.629.
        let p = try readRgbaFloat(output)[8][8]
        XCTAssertEqual(p.r, 0.629, accuracy: 0.02)
    }

    func testContrastOnBgra8UnormSourceProducesFloatOutput() throws {
        // DaVinci log-slope at contrast=+100, lumaMean=0.5, x=0.3:
        //   slope = exp2(1.585) ≈ 3
        //   y = 0.5·(0.3/0.5)^3 = 0.5·0.216 = 0.108
        let source = try makeBgra8UnormUniform(r: 0.3, g: 0.3, b: 0.3)
        let output = try runPipeline(
            source: source,
            steps: [.single(ContrastFilter(contrast: 100, lumaMean: 0.5, colorSpace: .perceptual))]
        )
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
        let p = try readRgbaFloat(output)[4][4]
        XCTAssertEqual(p.r, 0.108, accuracy: 0.02)
    }

    func testSharpenOnBgra8UnormStepEdgeProducesOvershoot() throws {
        // Sharpen's Laplacian overshoot derivation ports to bgra8Unorm input
        // without change — the 8-bit source is read into float in-shader.
        //   slider=100 → shader amount = 1.6, centerMul = 7.4
        //   col 7: 0.4·7.4 − 1.8·1.6 = 0.08
        //   col 8: 0.6·7.4 − 2.2·1.6 = 0.92
        let source = try makeBgra8UnormStepEdge(darkValue: 0.4, brightValue: 0.6, width: 16, height: 16)
        let output = try runPipeline(
            source: source,
            steps: [.single(SharpenFilter(amount: 100, step: 1))]
        )
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
        let pixels = try readRgbaFloat(output)
        XCTAssertEqual(pixels[8][7].r, 0.08, accuracy: 0.05)
        XCTAssertEqual(pixels[8][8].r, 0.92, accuracy: 0.05)
    }

    // MARK: - Multi-pass filter contracts

    func testSoftGlowOnBgra8UnormSourcePreservesGradient() throws {
        // Port of MultiPassFilterTests.testSoftGlowOutputIsNotSaturatedAt1...
        // but here we're building a per-filter contract test that parallels
        // the single-pass structure.
        let source = try makeBgra8UnormGradient(width: 64, height: 8)
        let output = try runPipeline(
            source: source,
            steps: [.multi(SoftGlowFilter(strength: 60, threshold: 30, bloomRadius: 50))]
        )
        XCTAssertEqual(output.pixelFormat, .rgba16Float)

        let pixels = try readRgbaFloat(output)
        var minR: Float = .infinity, maxR: Float = -.infinity
        for row in pixels {
            for p in row {
                minR = min(minR, p.r); maxR = max(maxR, p.r)
            }
        }
        XCTAssertGreaterThan(maxR - minR, 0.15, "Bloom saturation would collapse gradient (min=\(minR) max=\(maxR))")
    }

    // MARK: - Chain contracts (multiple filters in sequence)

    func testToneAdjustmentChainOnBgra8UnormSourcePreservesContract() throws {
        // A realistic 3-filter chain on a camera-style source. Verifies
        // that the precision stays float-valued end-to-end: each filter's
        // output feeds the next's input as rgba16Float.
        let source = try makeBgra8UnormUniform(r: 0.4, g: 0.4, b: 0.4)
        let output = try runPipeline(
            source: source,
            steps: [
                .single(ExposureFilter(exposure: 30)),
                .single(ContrastFilter(contrast: 40, lumaMean: 0.5)),
                .single(BlacksFilter(blacks: 20)),
            ]
        )
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
        let p = try readRgbaFloat(output)[4][4]
        XCTAssertTrue(p.r.isFinite)
        XCTAssertGreaterThanOrEqual(p.r, 0)
        XCTAssertLessThanOrEqual(p.r, 1)
        // Chain should visibly differ from identity. Exposure+30 brightens,
        // Contrast+40 at pivot≈0.57 with luma=0.4 pushes toward pivot,
        // Blacks+20 lifts shadows. Net effect is a small brightening.
        XCTAssertGreaterThan(p.r, 0.45, "Expected chain to brighten from 0.4, got r=\(p.r)")
    }

    func testMixedSingleAndMultiPassChainOnBgra8UnormSource() throws {
        // Chain: Exposure (single) → HighlightShadow (multi) → Contrast (single)
        // Exercises the precision-format hand-off between single-pass output
        // and multi-pass input (both must be rgba16Float).
        let source = try makeBgra8UnormUniform(r: 0.5, g: 0.5, b: 0.5, width: 32, height: 32)
        let output = try runPipeline(
            source: source,
            steps: [
                .single(ExposureFilter(exposure: 20)),
                .multi(HighlightShadowFilter(highlights: 50, shadows: -30)),
                .single(ContrastFilter(contrast: 30, lumaMean: 0.5)),
            ]
        )
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
        let p = try readRgbaFloat(output)[16][16]
        XCTAssertTrue(p.r.isFinite)
        XCTAssertGreaterThanOrEqual(p.r, 0)
        XCTAssertLessThanOrEqual(p.r, 1)
    }

    // MARK: - Dimension edge cases

    func testTinyBgra8UnormSourceDoesNotCrash() throws {
        // 1×1 is the smallest legal dimension. Some shaders compute block
        // offsets that can underflow on 1-pixel inputs.
        let source = try makeBgra8UnormUniform(r: 0.5, g: 0.5, b: 0.5, width: 1, height: 1)
        let output = try runPipeline(
            source: source,
            steps: [.single(ExposureFilter(exposure: 50))]
        )
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
        XCTAssertEqual(output.width, 1)
        XCTAssertEqual(output.height, 1)
    }

    func testNonSquareBgra8UnormSource() throws {
        // Tall + narrow (portrait-style) aspect ratios exercise threadgroup
        // sizing logic that can have off-by-one bugs on non-power-of-two
        // dimensions.
        let source = try makeBgra8UnormUniform(r: 0.5, g: 0.5, b: 0.5, width: 7, height: 23)
        let output = try runPipeline(
            source: source,
            steps: [.single(ExposureFilter(exposure: 50))]
        )
        XCTAssertEqual(output.width, 7)
        XCTAssertEqual(output.height, 23)
        XCTAssertEqual(output.pixelFormat, .rgba16Float)
    }

    // MARK: - Helpers

    private func runPipeline(source: MTLTexture, steps: [AnyFilter]) throws -> MTLTexture {
        let pipeline = Pipeline(
            intermediatePixelFormat: .rgba16Float,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: texturePool,
            commandBufferPool: commandBufferPool

        )
        return try pipeline.processSync(
            input: .texture(source),
            steps: steps
        )
    }
}

// MARK: - bgra8Unorm helpers (byte order: B, G, R, A)

private struct FloatPixel {
    var r: Float; var g: Float; var b: Float; var a: Float
}

private func makeBgra8UnormUniform(
    r: Float, g: Float, b: Float, alpha: Float = 1.0,
    width: Int = 8, height: Int = 8
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

    let bb = clampedByte(b), gb = clampedByte(g), rb = clampedByte(r), ab = clampedByte(alpha)
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

private func makeBgra8UnormStepEdge(
    darkValue: Float, brightValue: Float, width: Int, height: Int
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

    let dark = clampedByte(darkValue), bright = clampedByte(brightValue)
    let midCol = width / 2
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let v = x < midCol ? dark : bright
            let off = (y * width + x) * 4
            pixels[off + 0] = v
            pixels[off + 1] = v
            pixels[off + 2] = v
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

private func makeBgra8UnormGradient(width: Int, height: Int) throws -> MTLTexture {
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
            let v = clampedByte(0.2 + 0.6 * t)
            let off = (y * width + x) * 4
            pixels[off + 0] = v
            pixels[off + 1] = v
            pixels[off + 2] = v
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

private func clampedByte(_ v: Float) -> UInt8 {
    UInt8(min(max((v * 255.0).rounded(), 0), 255))
}

private func readRgbaFloat(_ texture: MTLTexture) throws -> [[FloatPixel]] {
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
    var result: [[FloatPixel]] = []
    for y in 0..<height {
        var row: [FloatPixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(FloatPixel(
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
