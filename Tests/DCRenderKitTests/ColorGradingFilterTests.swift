//
//  ColorGradingFilterTests.swift
//  DCRenderKitTests
//
//  Round 11 tests: DCR replacements for Harbeth's Saturation /
//  Vibrance / WhiteBalance / NormalBlend.
//

import XCTest
@testable import DCRenderKit
import Metal

final class ColorGradingFilterTests: XCTestCase {

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

    // MARK: - Saturation

    func testSaturationIdentityAtOne() throws {
        let source = try makeCGSource(red: 0.7, green: 0.3, blue: 0.5)
        let output = try runSingle(source, filter: SaturationFilter(saturation: 1.0))
        let p = try readCGTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.7, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.3, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.5, accuracy: 0.01)
    }

    func testSaturationZeroGoesGrayscale() throws {
        let source = try makeCGSource(red: 0.8, green: 0.2, blue: 0.4)
        let output = try runSingle(source, filter: SaturationFilter(saturation: 0))
        let p = try readCGTexture(output)[4][4]
        // All channels collapse to Rec.709 luma. For (0.8, 0.2, 0.4):
        // luma = 0.2125*0.8 + 0.7154*0.2 + 0.0721*0.4 = 0.3420.
        let expected: Float = 0.2125 * 0.8 + 0.7154 * 0.2 + 0.0721 * 0.4
        XCTAssertEqual(p.r, expected, accuracy: 0.02)
        XCTAssertEqual(p.g, expected, accuracy: 0.02)
        XCTAssertEqual(p.b, expected, accuracy: 0.02)
    }

    func testSaturationDoubleBoostsChroma() throws {
        // Colour with moderate chroma. Doubling saturation should move
        // further from luma, not further from zero.
        let source = try makeCGSource(red: 0.6, green: 0.4, blue: 0.5)
        let output = try runSingle(source, filter: SaturationFilter(saturation: 2.0))
        let p = try readCGTexture(output)[4][4]
        assertFinite(p)
        // Max channel (R) gets pushed further from luma than source.
        XCTAssertGreaterThan(p.r, 0.6)
    }

    func testSaturationFuseGroupIsColorGrading() {
        XCTAssertEqual(SaturationFilter.fuseGroup, .colorGrading)
    }

    // MARK: - Vibrance

    func testVibranceIdentityAtZero() throws {
        let source = try makeCGSource(red: 0.4, green: 0.6, blue: 0.8)
        let output = try runSingle(source, filter: VibranceFilter(vibrance: 0))
        let p = try readCGTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.4, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.6, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.8, accuracy: 0.01)
    }

    func testVibrancePositiveBoostsUndersaturated() throws {
        // Near-grayscale colour should be boosted toward saturation on +vibrance.
        let source = try makeCGSource(red: 0.5, green: 0.52, blue: 0.5)
        let output = try runSingle(source, filter: VibranceFilter(vibrance: 1.2))
        let p = try readCGTexture(output)[4][4]
        assertFinite(p)
        XCTAssertGreaterThanOrEqual(p.g, 0.52 - 1e-3)
    }

    func testVibranceExtremeStaysInGamut() throws {
        let source = try makeCGSource(red: 0.9, green: 0.1, blue: 0.1)
        let output = try runSingle(source, filter: VibranceFilter(vibrance: -1.2))
        let p = try readCGTexture(output)[4][4]
        assertFinite(p)
        XCTAssertGreaterThanOrEqual(p.r, 0)
        XCTAssertLessThanOrEqual(p.r, 1)
    }

    func testVibranceFuseGroupIsColorGrading() {
        XCTAssertEqual(VibranceFilter.fuseGroup, .colorGrading)
    }

    // MARK: - WhiteBalance

    func testWhiteBalanceIdentityAtNeutralKelvin() throws {
        let source = try makeCGSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source,
            filter: WhiteBalanceFilter(temperature: 5000, tint: 0, colorSpace: .perceptual)
        )
        let p = try readCGTexture(output)[4][4]
        // Neutral 5000K + zero tint is exact identity (tempCoef = 0, tint Q shift = 0).
        XCTAssertEqual(p.r, 0.5, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.5, accuracy: 0.02)
    }

    func testWhiteBalanceWarmShiftsRedAboveBlue() throws {
        let source = try makeCGSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source,
            filter: WhiteBalanceFilter(temperature: 7000, tint: 0, colorSpace: .perceptual)
        )
        let p = try readCGTexture(output)[4][4]
        assertFinite(p)
        // Warm target is (0.93, 0.54, 0.0). Mid-gray + warm overlay → R↑, B↓.
        XCTAssertGreaterThan(p.r, p.b)
    }

    func testWhiteBalanceCoolShiftsBlueAboveRed() throws {
        let source = try makeCGSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source,
            filter: WhiteBalanceFilter(temperature: 4200, tint: 0, colorSpace: .perceptual)
        )
        let p = try readCGTexture(output)[4][4]
        assertFinite(p)
        // Below 5000K, negative tempCoef → mixes away from warm target,
        // which has zero blue, so blue relative to red increases.
        XCTAssertGreaterThan(p.b, p.r)
    }

    func testWhiteBalanceTintMagentaPreservesNTSCLuma() throws {
        let source = try makeCGSource(red: 0.5, green: 0.5, blue: 0.5)
        let neutral = try runSingle(
            source,
            filter: WhiteBalanceFilter(temperature: 5000, tint: 0, colorSpace: .perceptual)
        )
        let magenta = try runSingle(
            source,
            filter: WhiteBalanceFilter(temperature: 5000, tint: 200, colorSpace: .perceptual)
        )
        let pn = try readCGTexture(neutral)[4][4]
        let pm = try readCGTexture(magenta)[4][4]

        // The shader operates in YIQ (NTSC) space: Q-axis tint preserves
        // the Y channel, which is Rec.601 luma. Verify against the same
        // coefficient set (not Rec.709, which YIQ-tinting does not preserve).
        let lumaN = 0.299 * pn.r + 0.587 * pn.g + 0.114 * pn.b
        let lumaM = 0.299 * pm.r + 0.587 * pm.g + 0.114 * pm.b
        XCTAssertEqual(lumaN, lumaM, accuracy: 0.02)
    }

    func testWhiteBalanceLinearMatchesPerceptualViaGammaWrap() throws {
        // Parity proof for WhiteBalance linear wrap.
        let gammaX: Float = 0.5
        let sourceGamma = try makeCGSource(red: gammaX, green: gammaX, blue: gammaX)
        let sourceLinear = try makeCGSource(
            red: powf(gammaX, 2.2), green: powf(gammaX, 2.2), blue: powf(gammaX, 2.2)
        )
        let pOut = try runSingle(
            sourceGamma,
            filter: WhiteBalanceFilter(temperature: 7000, tint: 150, colorSpace: .perceptual)
        )
        let lOut = try runSingle(
            sourceLinear,
            filter: WhiteBalanceFilter(temperature: 7000, tint: 150, colorSpace: .linear)
        )
        let pp = try readCGTexture(pOut)[4][4]
        let pl = try readCGTexture(lOut)[4][4]
        let plGammaR = powf(max(pl.r, 0), 1.0 / 2.2)
        let plGammaG = powf(max(pl.g, 0), 1.0 / 2.2)
        let plGammaB = powf(max(pl.b, 0), 1.0 / 2.2)
        XCTAssertEqual(plGammaR, pp.r, accuracy: 0.03, "R parity")
        XCTAssertEqual(plGammaG, pp.g, accuracy: 0.03, "G parity")
        XCTAssertEqual(plGammaB, pp.b, accuracy: 0.03, "B parity")
    }

    func testWhiteBalanceFuseGroupIsColorGrading() {
        XCTAssertEqual(WhiteBalanceFilter.fuseGroup, .colorGrading)
    }

    // MARK: - NormalBlend

    func testNormalBlendIntensityZeroReturnsSource() throws {
        let source = try makeCGSource(red: 0.3, green: 0.6, blue: 0.9)
        let overlay = try makeCGSource(red: 1.0, green: 0.0, blue: 0.0)  // solid red
        let output = try runSingle(
            source,
            filter: NormalBlendFilter(overlay: overlay, intensity: 0)
        )
        let p = try readCGTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.3, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.6, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.9, accuracy: 0.02)
    }

    func testNormalBlendIntensityOneWithOpaqueOverlayShowsOverlay() throws {
        let source = try makeCGSource(red: 0.3, green: 0.6, blue: 0.9)
        let overlay = try makeCGSource(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let output = try runSingle(
            source,
            filter: NormalBlendFilter(overlay: overlay, intensity: 1.0)
        )
        let p = try readCGTexture(output)[4][4]
        // Overlay covers entire source with alpha=1 → pure overlay colour.
        XCTAssertEqual(p.r, 1.0, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.0, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.0, accuracy: 0.02)
    }

    func testNormalBlendTransparentOverlayLeavesSource() throws {
        // Premultiplied-alpha convention (see NormalBlendFilter docs):
        // fully transparent pixels have RGB = 0.
        let source = try makeCGSource(red: 0.4, green: 0.4, blue: 0.4)
        let overlay = try makeCGSource(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        let output = try runSingle(
            source,
            filter: NormalBlendFilter(overlay: overlay, intensity: 1.0)
        )
        let p = try readCGTexture(output)[4][4]
        // α=0 premultiplied overlay contributes nothing; source comes through.
        XCTAssertEqual(p.r, 0.4, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.4, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.4, accuracy: 0.02)
    }

    func testNormalBlendFuseGroupIsNil() {
        XCTAssertNil(NormalBlendFilter.fuseGroup)
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

    private func assertFinite(_ p: CGPixel, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(p.r.isFinite, "R not finite", file: file, line: line)
        XCTAssertTrue(p.g.isFinite, "G not finite", file: file, line: line)
        XCTAssertTrue(p.b.isFinite, "B not finite", file: file, line: line)
    }
}

// MARK: - Private utilities

private struct CGPixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeCGSource(
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

private func readCGTexture(_ texture: MTLTexture) throws -> [[CGPixel]] {
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
    var result: [[CGPixel]] = []
    for y in 0..<height {
        var row: [CGPixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(CGPixel(
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
