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
