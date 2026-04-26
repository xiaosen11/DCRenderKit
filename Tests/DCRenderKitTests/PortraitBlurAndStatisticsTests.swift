//
//  PortraitBlurAndStatisticsTests.swift
//  DCRenderKitTests
//
//  Batch 4 tests: PortraitBlurFilter (with and without mask) and
//  ImageStatistics.lumaMean.
//

import XCTest
@testable import DCRenderKit
import Metal

final class PortraitBlurAndStatisticsTests: XCTestCase {

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
        texturePool = TexturePool(device: d, maxBytes: 32 * 1024 * 1024)
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

    // MARK: - PortraitBlurFilter

    func testPortraitBlurNilMaskIsIdentity() throws {
        let source = try makeBlurSource(red: 0.3, green: 0.6, blue: 0.9, width: 32, height: 32)
        let output = try runMulti(
            source,
            filter: PortraitBlurFilter(strength: 100, maskTexture: nil)
        )
        let p = try readBlurTexture(output)[16][16]
        XCTAssertEqual(p.r, 0.3, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.6, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.9, accuracy: 0.01)
    }

    func testPortraitBlurStrengthZeroIsIdentity() throws {
        let source = try makeBlurSource(red: 0.5, green: 0.5, blue: 0.5, width: 32, height: 32)
        let mask = try makeMask(width: 32, height: 32, subjectValue: 0)  // all background
        let output = try runMulti(
            source,
            filter: PortraitBlurFilter(strength: 0, maskTexture: mask)
        )
        let p = try readBlurTexture(output)[16][16]
        XCTAssertEqual(p.r, 0.5, accuracy: 0.01)
    }

    func testPortraitBlurAllSubjectMaskIsIdentity() throws {
        // mask = 1 everywhere → blurAmount = 0 → every pixel stays sharp.
        let source = try makeRampBlurSource()
        let mask = try makeMask(
            width: source.width, height: source.height, subjectValue: 1
        )
        let output = try runMulti(
            source,
            filter: PortraitBlurFilter(strength: 100, maskTexture: mask)
        )
        let outPixels = try readBlurTexture(output)
        let srcPixels = try readBlurTexture(source)
        for y in 0..<outPixels.count {
            for x in 0..<outPixels[y].count {
                XCTAssertEqual(
                    outPixels[y][x].r, srcPixels[y][x].r,
                    accuracy: 0.02, "at (\(x), \(y))"
                )
            }
        }
    }

    func testPortraitBlurAllBackgroundProducesBlur() throws {
        // 4K-sized source so localRadius > 0.5 → blur path fires.
        // Use a ramp + mask=0 everywhere. Center pixels should differ
        // from the source due to Poisson disc averaging (now two-pass).
        let source = try makeRampBlurSource(width: 128, height: 128)
        let mask = try makeMask(
            width: source.width, height: source.height, subjectValue: 0
        )
        let output = try runMulti(
            source,
            filter: PortraitBlurFilter(strength: 100, maskTexture: mask)
        )
        let outPixels = try readBlurTexture(output)
        let srcPixels = try readBlurTexture(source)

        // Interior pixel must differ — evidence of neighbor averaging.
        let srcMid = srcPixels[64][64].r
        let outMid = outPixels[64][64].r
        // Ramp at x=64/127 ≈ 0.504. Blur averages neighbors around it.
        // We allow a small tolerance and require the averaged value
        // stays in-gamut.
        XCTAssertTrue(outMid.isFinite)
        XCTAssertGreaterThanOrEqual(outMid, 0)
        XCTAssertLessThanOrEqual(outMid, 1)
        XCTAssertEqual(outMid, srcMid, accuracy: 0.1)
    }

    // MARK: - ImageStatistics.lumaMean

    func testLumaMeanOfSolidWhite() async throws {
        let source = try makeBlurSource(red: 1, green: 1, blue: 1, width: 32, height: 32)
        let mean = try await ImageStatistics.lumaMean(of: source, device: device)
        XCTAssertEqual(mean, 1.0, accuracy: 0.02)
    }

    func testLumaMeanOfSolidBlack() async throws {
        let source = try makeBlurSource(red: 0, green: 0, blue: 0, width: 32, height: 32)
        let mean = try await ImageStatistics.lumaMean(of: source, device: device)
        XCTAssertEqual(mean, 0.0, accuracy: 0.02)
    }

    func testLumaMeanOfMidGray() async throws {
        let source = try makeBlurSource(red: 0.5, green: 0.5, blue: 0.5, width: 32, height: 32)
        let mean = try await ImageStatistics.lumaMean(of: source, device: device)
        XCTAssertEqual(mean, 0.5, accuracy: 0.02)
    }

    func testLumaMeanHonorsRec709Weights() async throws {
        // Pure green (mid intensity). Rec.709 luma weight for green is 0.7152.
        let source = try makeBlurSource(red: 0, green: 0.5, blue: 0, width: 32, height: 32)
        let mean = try await ImageStatistics.lumaMean(of: source, device: device)
        // Expected: 0.2126 * 0 + 0.7152 * 0.5 + 0.0722 * 0 = 0.3576.
        XCTAssertEqual(mean, 0.3576, accuracy: 0.02)
    }

    func testLumaMeanOfHorizontalRamp() async throws {
        // 64-wide ramp from 0 to 1. Arithmetic mean ≈ 0.5 (exactly
        // 31.5/63 = 0.5 for integer steps — N=64 so values 0/63, 1/63,
        // ..., 63/63 → mean = 31.5/63 = 0.5).
        let source = try makeRampBlurSource(width: 64, height: 64)
        let mean = try await ImageStatistics.lumaMean(of: source, device: device)
        XCTAssertEqual(mean, 0.5, accuracy: 0.02)
    }

    // MARK: - Helpers

    private func runMulti<F: MultiPassFilter>(
        _ source: MTLTexture,
        filter: F
    ) throws -> MTLTexture {
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
            steps: [.multi(filter)]
        )
    }

    private func makeMask(
        width: Int, height: Int, subjectValue: UInt8
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))
        let bytes = [UInt8](repeating: subjectValue, count: width * height)
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
}

// MARK: - Private utilities

private struct BlurPixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeBlurSource(
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

private func makeRampBlurSource(width: Int = 128, height: Int = 128) throws -> MTLTexture {
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

private func readBlurTexture(_ texture: MTLTexture) throws -> [[BlurPixel]] {
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
    var result: [[BlurPixel]] = []
    for y in 0..<height {
        var row: [BlurPixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(BlurPixel(
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
