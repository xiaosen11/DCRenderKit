//
//  OKLabConversionTests.swift
//  DCRenderKitTests
//
//  Tests for the OKLab / OKLCh helpers defined in
//  `Shaders/Foundation/OKLab.metal`. Covers:
//
//  - Round-trip identity (linear sRGB → OKLab → linear sRGB) across
//    primaries, white, grayscale, and out-of-gamut extremes.
//  - Known-value assertions against Ottosson's published reference
//    OKLab coordinates for pure sRGB primaries and white.
//  - Grayscale invariant: R = G = B → OKLCh C ≈ 0.
//  - OKLCh ↔ OKLab cylindrical-form round-trip.
//  - Gamut clamp: amplifying chroma pushes the result out of gamut;
//    the clamp brings it back inside `[0, 1]³`.
//
//  References:
//    Ottosson (2020) — https://bottosson.github.io/posts/oklab/
//    Ottosson (2021) gamut clipping — https://bottosson.github.io/posts/gamutclipping/
//

import XCTest
@testable import DCRenderKit
import Metal

final class OKLabConversionTests: XCTestCase {

    // MARK: - Fixtures

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

    // MARK: - Round-trip identity

    /// Mid-gray (0.5, 0.5, 0.5) should survive rgb → OKLab → rgb.
    func testRoundTripMidGray() throws {
        try assertRoundTrip(r: 0.5, g: 0.5, b: 0.5, tolerance: 0.01)
    }

    /// Pure primaries should survive round trip.
    func testRoundTripPrimaries() throws {
        try assertRoundTrip(r: 1.0, g: 0.0, b: 0.0, tolerance: 0.01)
        try assertRoundTrip(r: 0.0, g: 1.0, b: 0.0, tolerance: 0.01)
        try assertRoundTrip(r: 0.0, g: 0.0, b: 1.0, tolerance: 0.01)
    }

    /// Mixed colours across the gamut.
    func testRoundTripAssortedColours() throws {
        try assertRoundTrip(r: 0.7, g: 0.3, b: 0.5, tolerance: 0.01)
        try assertRoundTrip(r: 0.2, g: 0.8, b: 0.4, tolerance: 0.01)
        try assertRoundTrip(r: 0.9, g: 0.6, b: 0.1, tolerance: 0.01)
    }

    /// White (1, 1, 1) — edge case, maximum lightness.
    func testRoundTripWhite() throws {
        try assertRoundTrip(r: 1.0, g: 1.0, b: 1.0, tolerance: 0.01)
    }

    /// Black (0, 0, 0) — another edge case, minimum lightness.
    func testRoundTripBlack() throws {
        try assertRoundTrip(r: 0.0, g: 0.0, b: 0.0, tolerance: 0.005)
    }

    // MARK: - Known OKLab coordinates (from Ottosson 2020)

    /// White in OKLab: (L=1, a=0, b=0). Derivation:
    ///   LMS matrix rows sum to 1 (matrix is balanced for white).
    ///   → l = m = s = 1 → l' = m' = s' = 1.
    ///   M2 rows: L row sums to 1, a and b rows sum to 0.
    ///   → L = 1, a = 0, b = 0.
    func testWhiteOKLabCoordinates() throws {
        let lab = try extractLab(r: 1.0, g: 1.0, b: 1.0)
        XCTAssertEqual(lab.l, 1.0, accuracy: 0.005, "White L should be 1")
        XCTAssertEqual(lab.a, 0.0, accuracy: 0.005, "White a should be 0")
        XCTAssertEqual(lab.b, 0.0, accuracy: 0.005, "White b should be 0")
    }

    /// Red in OKLab (from manual computation using Ottosson's matrices):
    ///   l = 0.4122214708, m = 0.2119034982, s = 0.0883024619
    ///   l' = ∛0.4122 ≈ 0.7440, m' = ∛0.2119 ≈ 0.5960, s' = ∛0.0883 ≈ 0.4453
    ///   L = 0.2105·0.7440 + 0.7936·0.5960 − 0.0041·0.4453 ≈ 0.6279
    ///   a = 1.9780·0.7440 − 2.4286·0.5960 + 0.4506·0.4453 ≈ 0.2249
    ///   b = 0.0259·0.7440 + 0.7828·0.5960 − 0.8087·0.4453 ≈ 0.1258
    /// Tolerance: 0.005 covers Float16 quantization + matrix rounding.
    func testRedOKLabCoordinates() throws {
        let lab = try extractLab(r: 1.0, g: 0.0, b: 0.0)
        XCTAssertEqual(lab.l, 0.6279, accuracy: 0.005)
        XCTAssertEqual(lab.a, 0.2249, accuracy: 0.005)
        XCTAssertEqual(lab.b, 0.1258, accuracy: 0.005)
    }

    /// Green in OKLab (same derivation method):
    ///   L ≈ 0.8664, a ≈ −0.2339, b ≈ 0.1794.
    func testGreenOKLabCoordinates() throws {
        let lab = try extractLab(r: 0.0, g: 1.0, b: 0.0)
        XCTAssertEqual(lab.l, 0.8664, accuracy: 0.005)
        XCTAssertEqual(lab.a, -0.2339, accuracy: 0.005)
        XCTAssertEqual(lab.b, 0.1794, accuracy: 0.005)
    }

    /// Blue in OKLab:
    ///   L ≈ 0.4520, a ≈ −0.0324, b ≈ −0.3115.
    func testBlueOKLabCoordinates() throws {
        let lab = try extractLab(r: 0.0, g: 0.0, b: 1.0)
        XCTAssertEqual(lab.l, 0.4520, accuracy: 0.005)
        XCTAssertEqual(lab.a, -0.0324, accuracy: 0.005)
        XCTAssertEqual(lab.b, -0.3115, accuracy: 0.005)
    }

    // MARK: - Grayscale invariant: R = G = B ⇒ C ≈ 0

    func testGrayscalePreservesChromaZero() throws {
        // Scan several grey levels; all should collapse to C ≈ 0.
        for level: Float in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let lch = try extractLCh(r: level, g: level, b: level)
            XCTAssertLessThan(
                lch.c, 0.002,
                "Grey level \(level) should have near-zero OKLCh chroma, got \(lch.c)"
            )
        }
    }

    // MARK: - OKLab ↔ OKLCh round trip

    /// `OKLCh.C = sqrt(a² + b²)` must match the direct Lab → LCh
    /// calculation for arbitrary in-gamut inputs.
    func testOKLChMatchesCartesianToPolar() throws {
        let lab = try extractLab(r: 0.7, g: 0.3, b: 0.5)
        let lch = try extractLCh(r: 0.7, g: 0.3, b: 0.5)
        XCTAssertEqual(lch.l, lab.l, accuracy: 0.005)
        XCTAssertEqual(lch.c, sqrt(lab.a * lab.a + lab.b * lab.b), accuracy: 0.005)
        XCTAssertEqual(lch.h, atan2(lab.b, lab.a), accuracy: 0.01)
    }

    // MARK: - Gamut clamp

    /// Amplifying chroma by 1× must leave in-gamut inputs unchanged.
    func testGamutClampIdentityWhenInGamut() throws {
        // Pastel input — well inside gamut even at x1 chroma.
        let clamped = try runGamutClamp(r: 0.55, g: 0.45, b: 0.50, chromaMultiplier: 1.0)
        XCTAssertEqual(clamped.r, 0.55, accuracy: 0.01)
        XCTAssertEqual(clamped.g, 0.45, accuracy: 0.01)
        XCTAssertEqual(clamped.b, 0.50, accuracy: 0.01)
    }

    /// Amplifying chroma by 5× pushes pure red far out of gamut; the
    /// clamp must bring it back inside `[0, 1]³`.
    func testGamutClampBringsOutOfGamutBackIn() throws {
        let clamped = try runGamutClamp(r: 1.0, g: 0.0, b: 0.0, chromaMultiplier: 5.0)
        // 1/4096 margin tolerated. Float16 output quantization ~2e-3.
        XCTAssertGreaterThanOrEqual(clamped.r, -0.01)
        XCTAssertLessThanOrEqual(clamped.r, 1.01)
        XCTAssertGreaterThanOrEqual(clamped.g, -0.01)
        XCTAssertLessThanOrEqual(clamped.g, 1.01)
        XCTAssertGreaterThanOrEqual(clamped.b, -0.01)
        XCTAssertLessThanOrEqual(clamped.b, 1.01)
    }

    // MARK: - Helpers

    private struct LabPixel { var l: Float; var a: Float; var b: Float }
    private struct LChPixel { var l: Float; var c: Float; var h: Float }
    private struct RGBPixel { var r: Float; var g: Float; var b: Float }

    private func assertRoundTrip(
        r: Float, g: Float, b: Float, tolerance: Float,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let source = try makeRGB16FSource(r: r, g: g, b: b)
        let output = try runFilter(source, filter: OKLabRoundTripFilter())
        let p = try readRGB(output)
        XCTAssertEqual(p.r, r, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(p.g, g, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(p.b, b, accuracy: tolerance, file: file, line: line)
    }

    private func extractLab(r: Float, g: Float, b: Float) throws -> LabPixel {
        let source = try makeRGB16FSource(r: r, g: g, b: b)
        let output = try runFilter(source, filter: OKLabExposeLabFilter())
        let p = try readRGB(output)
        return LabPixel(l: p.r, a: p.g, b: p.b)
    }

    private func extractLCh(r: Float, g: Float, b: Float) throws -> LChPixel {
        let source = try makeRGB16FSource(r: r, g: g, b: b)
        let output = try runFilter(source, filter: OKLabExposeLChFilter())
        let p = try readRGB(output)
        return LChPixel(l: p.r, c: p.g, h: p.b)
    }

    private func runGamutClamp(
        r: Float, g: Float, b: Float, chromaMultiplier: Float
    ) throws -> RGBPixel {
        let source = try makeRGB16FSource(r: r, g: g, b: b)
        let output = try runFilter(source, filter: OKLabGamutClampFilter(chromaMultiplier: chromaMultiplier))
        return try readRGB(output)
    }

    private func runFilter<F: FilterProtocol>(
        _ source: MTLTexture, filter: F
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

    private func makeRGB16FSource(
        r: Float, g: Float, b: Float, width: Int = 4, height: Int = 4
    ) throws -> MTLTexture {
        guard let metalDevice = Device.tryShared?.metalDevice else {
            throw XCTSkip("Metal device required")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(metalDevice.makeTexture(descriptor: desc))
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let hr = Float16(r).bitPattern
        let hg = Float16(g).bitPattern
        let hb = Float16(b).bitPattern
        let ha = Float16(1.0).bitPattern
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

    private func readRGB(_ texture: MTLTexture) throws -> RGBPixel {
        guard let metalDevice = Device.tryShared?.metalDevice else {
            throw XCTSkip("Metal device required")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width, height: texture.height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let staging = try XCTUnwrap(metalDevice.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(metalDevice.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try BlitDispatcher.copy(source: texture, destination: staging, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var raw = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes { bytes in
            staging.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        // Sample the centre pixel so any border artefacts don't bias the read.
        let cx = texture.width / 2
        let cy = texture.height / 2
        let offset = (cy * texture.width + cx) * 4
        return RGBPixel(
            r: Float(Float16(bitPattern: raw[offset + 0])),
            g: Float(Float16(bitPattern: raw[offset + 1])),
            b: Float(Float16(bitPattern: raw[offset + 2]))
        )
    }
}

// MARK: - Test-only filter wrappers

/// Wraps the `DCROKLabRoundTripTestKernel` as a `FilterProtocol` so it
/// can be driven through the standard `Pipeline` + dispatcher stack.
private struct OKLabRoundTripFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCROKLabRoundTripTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}

private struct OKLabExposeLabFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCROKLabExposeLabTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}

private struct OKLabExposeLChFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCROKLabExposeLChTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}

private struct OKLabGamutClampFilter: FilterProtocol {
    var chromaMultiplier: Float
    var modifier: ModifierEnum { .compute(kernel: "DCROKLabGamutClampTestKernel") }
    var uniforms: FilterUniforms {
        FilterUniforms(OKLabGamutClampUniforms(chromaMultiplier: chromaMultiplier))
    }
    static var fuseGroup: FuseGroup? { nil }
}

/// Layout must match `DCROKLabGamutClampTestUniforms` in OKLab.metal.
private struct OKLabGamutClampUniforms {
    var chromaMultiplier: Float
}
