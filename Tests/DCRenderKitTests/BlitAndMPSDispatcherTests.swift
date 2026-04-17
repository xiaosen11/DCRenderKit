//
//  BlitAndMPSDispatcherTests.swift
//  DCRenderKitTests
//
//  Tests for BlitDispatcher (texture copy, region crop, mipmap generation)
//  and MPSDispatcher (availability probe, Gaussian blur, statistics mean,
//  Lanczos resampling).
//

import XCTest
@testable import DCRenderKit
import Metal

// MARK: - BlitDispatcher

final class BlitDispatcherTests: XCTestCase {

    var device: Device!

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

    // MARK: - Copy

    func testCopyEntireTexture() throws {
        let source = try makeFilled(width: 8, height: 8, r: 1, g: 0.5, b: 0)
        let dest = try makeWritable(width: 8, height: 8)

        let buffer = try device.makeCommandBuffer()
        try BlitDispatcher.copy(
            source: source,
            destination: dest,
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        let pixels = try readRGBA16(texture: dest)
        XCTAssertEqual(pixels[0][0].r, 1.0, accuracy: 0.02)
        XCTAssertEqual(pixels[0][0].g, 0.5, accuracy: 0.02)
    }

    func testCopyFormatMismatchThrows() throws {
        let source = try makeFilled(width: 8, height: 8, r: 0, g: 0, b: 0)
        // Different format: bgra8Unorm.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        let dest = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let buffer = try device.makeCommandBuffer()
        do {
            try BlitDispatcher.copy(
                source: source,
                destination: dest,
                commandBuffer: buffer
            )
            XCTFail("Expected throw")
        } catch PipelineError.texture(.formatMismatch) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testCopyDimensionMismatchThrows() throws {
        let source = try makeFilled(width: 8, height: 8, r: 0, g: 0, b: 0)
        let dest = try makeWritable(width: 16, height: 16)

        let buffer = try device.makeCommandBuffer()
        do {
            try BlitDispatcher.copy(
                source: source,
                destination: dest,
                commandBuffer: buffer
            )
            XCTFail("Expected throw")
        } catch PipelineError.texture(.formatMismatch) {
            // Expected — dimension mismatch surfaces via same error type
            // (message content distinguishes format vs dimension).
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Copy region

    func testCopyRegionCrop() throws {
        let source = try makeFilled(width: 8, height: 8, r: 1, g: 0, b: 0)
        let dest = try makeWritable(width: 4, height: 4)

        let sourceRegion = MTLRegion(
            origin: MTLOrigin(x: 2, y: 2, z: 0),
            size: MTLSize(width: 4, height: 4, depth: 1)
        )

        let buffer = try device.makeCommandBuffer()
        try BlitDispatcher.copyRegion(
            source: source,
            sourceRegion: sourceRegion,
            destination: dest,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        let pixels = try readRGBA16(texture: dest)
        XCTAssertEqual(pixels[0][0].r, 1.0, accuracy: 0.02)
    }

    func testCopyRegionOutOfBoundsThrows() throws {
        let source = try makeFilled(width: 8, height: 8, r: 0, g: 0, b: 0)
        let dest = try makeWritable(width: 8, height: 8)

        // Region extends past source.
        let badRegion = MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: 16, height: 16, depth: 1)
        )

        let buffer = try device.makeCommandBuffer()
        do {
            try BlitDispatcher.copyRegion(
                source: source,
                sourceRegion: badRegion,
                destination: dest,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                commandBuffer: buffer
            )
            XCTFail("Expected throw")
        } catch PipelineError.texture(.dimensionsInvalid) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Mipmap

    func testGenerateMipmapsRequiresMipLevels() throws {
        // Texture with only 1 mip level — mipmap gen should throw.
        let tex = try makeWritable(width: 8, height: 8)
        XCTAssertEqual(tex.mipmapLevelCount, 1)

        let buffer = try device.makeCommandBuffer()
        do {
            try BlitDispatcher.generateMipmaps(texture: tex, commandBuffer: buffer)
            XCTFail("Expected throw")
        } catch PipelineError.texture(.dimensionsInvalid) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testGenerateMipmapsWithMipLevels() throws {
        // Texture with mip levels — should succeed.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 16, height: 16, mipmapped: true
        )
        desc.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        desc.storageMode = .private
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))
        XCTAssertGreaterThan(tex.mipmapLevelCount, 1)

        let buffer = try device.makeCommandBuffer()
        try BlitDispatcher.generateMipmaps(texture: tex, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
    }
}

// MARK: - MPSDispatcher

final class MPSDispatcherTests: XCTestCase {

    var device: Device!

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

    func testAvailability() {
        // On iOS/macOS CI, MPS is always available.
        XCTAssertTrue(MPSDispatcher.isAvailable)
    }

    func testGaussianBlurPreservesDimensions() throws {
        try XCTSkipUnless(MPSDispatcher.isAvailable, "MPS required")

        let source = try makeFilled(width: 32, height: 32, r: 1, g: 0, b: 0)
        let dest = try makeWritable(width: 32, height: 32)

        let buffer = try device.makeCommandBuffer()
        try MPSDispatcher.gaussianBlur(
            source: source,
            destination: dest,
            sigma: 2.0,
            device: device,
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        // Uniform red input blurred = uniform red output (for areas away
        // from edges, which for a 32x32 with sigma 2 means interior pixels
        // are still red).
        let pixels = try readRGBA16(texture: dest)
        XCTAssertEqual(pixels[16][16].r, 1.0, accuracy: 0.05)
    }

    func testGaussianBlurZeroSigmaCopies() throws {
        try XCTSkipUnless(MPSDispatcher.isAvailable, "MPS required")

        let source = try makeFilled(width: 8, height: 8, r: 0.7, g: 0, b: 0)
        let dest = try makeWritable(width: 8, height: 8)

        let buffer = try device.makeCommandBuffer()
        // sigma=0: no-op fallback to blit copy.
        try MPSDispatcher.gaussianBlur(
            source: source,
            destination: dest,
            sigma: 0,
            device: device,
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        let pixels = try readRGBA16(texture: dest)
        XCTAssertEqual(pixels[4][4].r, 0.7, accuracy: 0.02)
    }

    func testMeanReductionProducesValidTexture() throws {
        try XCTSkipUnless(MPSDispatcher.isAvailable, "MPS required")

        let source = try makeFilled(width: 64, height: 64, r: 0.5, g: 0.25, b: 0.1)

        let buffer = try device.makeCommandBuffer()
        let meanTexture = try MPSDispatcher.encodeMeanReduction(
            source: source,
            device: device,
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        XCTAssertEqual(meanTexture.width, 1)
        XCTAssertEqual(meanTexture.height, 1)

        // For uniform input, mean should equal the uniform value.
        let pixels = try readRGBA16(texture: meanTexture)
        XCTAssertEqual(pixels[0][0].r, 0.5, accuracy: 0.02)
        XCTAssertEqual(pixels[0][0].g, 0.25, accuracy: 0.02)
    }

    func testLanczosScaleDownsample() throws {
        try XCTSkipUnless(MPSDispatcher.isAvailable, "MPS required")

        let source = try makeFilled(width: 64, height: 64, r: 0.5, g: 0.5, b: 0.5)
        let dest = try makeWritable(width: 32, height: 32)

        let buffer = try device.makeCommandBuffer()
        try MPSDispatcher.lanczosResample(
            source: source,
            destination: dest,
            device: device,
            commandBuffer: buffer
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        // Uniform input downsampled remains uniform.
        let pixels = try readRGBA16(texture: dest)
        XCTAssertEqual(pixels[16][16].r, 0.5, accuracy: 0.05)
    }
}

// MARK: - Helpers (shared with other dispatcher tests)

private struct RGBA16 {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeFilled(
    width: Int, height: Int,
    r: Float, g: Float, b: Float, a: Float = 1
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let hr = Float16(r).bitPattern
    let hg = Float16(g).bitPattern
    let hb = Float16(b).bitPattern
    let ha = Float16(a).bitPattern
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

private func makeWritable(width: Int, height: Int) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    return try XCTUnwrap(device.makeTexture(descriptor: desc))
}

private func readRGBA16(texture: MTLTexture) throws -> [[RGBA16]] {
    let width = texture.width
    let height = texture.height
    var raw = [UInt16](repeating: 0, count: width * height * 4)
    raw.withUnsafeMutableBytes { bytes in
        texture.getBytes(
            bytes.baseAddress!,
            bytesPerRow: width * 8,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    var result: [[RGBA16]] = []
    for y in 0..<height {
        var row: [RGBA16] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(RGBA16(
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
