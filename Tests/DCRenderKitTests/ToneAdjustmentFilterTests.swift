//
//  ToneAdjustmentFilterTests.swift
//  DCRenderKitTests
//
//  Identity + extreme tests for the four tone-adjustment filters
//  (Exposure / Contrast / Whites / Blacks). Uses the SDK's default
//  shader library loaded from SPM resources.
//

import XCTest
@testable import DCRenderKit
import Metal

final class ToneAdjustmentFilterTests: XCTestCase {

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

        // Wipe any per-test library registrations, then let ShaderLibrary
        // lazily load the SPM-bundled default.metallib (which contains the
        // real DCR* kernels we want to exercise).
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

    // MARK: - Exposure

    func testExposureIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.4, green: 0.5, blue: 0.6)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 0))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.4, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.6, accuracy: 0.01)
    }

    func testExposurePositiveExtremeIsSafe() throws {
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 100))
        let p = try readToneTexture(output)[4][4]
        assertFinite(p)
        XCTAssertGreaterThan(p.r, 0.3)
        XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3)
    }

    func testExposureNegativeExtremeIsSafe() throws {
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(source, filter: ExposureFilter(exposure: -100))
        let p = try readToneTexture(output)[4][4]
        assertFinite(p)
        XCTAssertLessThan(p.r, 0.7)
        XCTAssertGreaterThanOrEqual(p.r, -1e-3)
    }

    // MARK: - Contrast

    func testContrastIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.42, green: 0.55, blue: 0.18)
        let output = try runSingle(source, filter: ContrastFilter(contrast: 0, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.42, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.55, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.18, accuracy: 0.01)
    }

    func testContrastExtremesClampAndStayFinite() throws {
        for (slider, luma) in [(100, Float(0.5)), (-100, Float(0.3)), (100, Float(0.8)), (-100, Float(0.2))] {
            let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
            let output = try runSingle(
                source,
                filter: ContrastFilter(contrast: Float(slider), lumaMean: luma)
            )
            let p = try readToneTexture(output)[4][4]
            assertFinite(p)
            XCTAssertGreaterThanOrEqual(p.r, -1e-3, "slider=\(slider) luma=\(luma)")
            XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3, "slider=\(slider) luma=\(luma)")
        }
    }

    // MARK: - Whites

    func testWhitesIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.6, green: 0.3, blue: 0.9)
        let output = try runSingle(source, filter: WhitesFilter(whites: 0, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.6, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.3, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.9, accuracy: 0.01)
    }

    func testWhitesExtremesClampAndStayFinite() throws {
        for (slider, luma) in [(100, Float(0.4)), (-100, Float(0.6)), (100, Float(0.29)), (-100, Float(0.6))] {
            let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
            let output = try runSingle(
                source,
                filter: WhitesFilter(whites: Float(slider), lumaMean: luma)
            )
            let p = try readToneTexture(output)[4][4]
            assertFinite(p)
            XCTAssertGreaterThanOrEqual(p.r, -1e-3, "slider=\(slider) luma=\(luma)")
            XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3, "slider=\(slider) luma=\(luma)")
        }
    }

    func testWhitesLUTInterpolationEdgeClamp() {
        let lowEnd = WhitesFilter.lutInterpolate(lumaMean: 0.1)
        let lowAnchor = WhitesFilter.lutInterpolate(lumaMean: 0.2877)
        XCTAssertEqual(lowEnd.k100, lowAnchor.k100, accuracy: 1e-6)
        XCTAssertEqual(lowEnd.b, lowAnchor.b, accuracy: 1e-6)

        let highEnd = WhitesFilter.lutInterpolate(lumaMean: 0.9)
        let highAnchor = WhitesFilter.lutInterpolate(lumaMean: 0.6004)
        XCTAssertEqual(highEnd.k100, highAnchor.k100, accuracy: 1e-6)
        XCTAssertEqual(highEnd.b, highAnchor.b, accuracy: 1e-6)
    }

    // MARK: - Blacks

    func testBlacksIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.15, green: 0.35, blue: 0.55)
        let output = try runSingle(source, filter: BlacksFilter(blacks: 0))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.15, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.35, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.55, accuracy: 0.01)
    }

    func testBlacksPositiveLiftsShadows() throws {
        let source = try makeToneSource(red: 0.1, green: 0.1, blue: 0.1)
        let output = try runSingle(source, filter: BlacksFilter(blacks: 100))
        let p = try readToneTexture(output)[4][4]
        assertFinite(p)
        XCTAssertGreaterThan(p.r, 0.1)
    }

    func testBlacksNegativeCrushesShadows() throws {
        let source = try makeToneSource(red: 0.2, green: 0.2, blue: 0.2)
        let output = try runSingle(source, filter: BlacksFilter(blacks: -100))
        let p = try readToneTexture(output)[4][4]
        assertFinite(p)
        XCTAssertLessThan(p.r, 0.2)
        XCTAssertGreaterThanOrEqual(p.r, 0)
    }

    // MARK: - Fuse group registration

    func testAllFourDeclareToneAdjustmentFuseGroup() {
        XCTAssertEqual(ExposureFilter.fuseGroup, .toneAdjustment)
        XCTAssertEqual(ContrastFilter.fuseGroup, .toneAdjustment)
        XCTAssertEqual(WhitesFilter.fuseGroup, .toneAdjustment)
        XCTAssertEqual(BlacksFilter.fuseGroup, .toneAdjustment)
    }

    // MARK: - Helpers

    private func runSingle<F: FilterProtocol>(
        _ source: MTLTexture,
        filter: F
    ) throws -> MTLTexture {
        let pipeline = Pipeline(
            input: .texture(source),
            steps: [.single(filter)],
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
        return try pipeline.outputSync()
    }

    private func assertFinite(_ p: TonePixel, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(p.r.isFinite, "R not finite", file: file, line: line)
        XCTAssertTrue(p.g.isFinite, "G not finite", file: file, line: line)
        XCTAssertTrue(p.b.isFinite, "B not finite", file: file, line: line)
        XCTAssertTrue(p.a.isFinite, "A not finite", file: file, line: line)
    }
}

// MARK: - Private test utilities

private struct TonePixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeToneSource(
    red: Float, green: Float, blue: Float, alpha: Float = 1.0,
    width: Int = 8, height: Int = 8
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

private func readToneTexture(_ texture: MTLTexture) throws -> [[TonePixel]] {
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
    var result: [[TonePixel]] = []
    for y in 0..<height {
        var row: [TonePixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(TonePixel(
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
