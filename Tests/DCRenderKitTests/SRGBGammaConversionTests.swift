//
//  SRGBGammaConversionTests.swift
//  DCRenderKitTests
//
//  Tests for the IEC 61966-2-1 piecewise sRGB transfer function
//  helpers defined in `Shaders/Foundation/SRGBGamma.metal`:
//
//  - `DCRSRGBLinearToGamma(c)`
//  - `DCRSRGBGammaToLinear(c)`
//
//  Covers:
//
//  - Round-trip identity across endpoints, midpoints, and every Zone-
//    System midpoint (13, 38, 64, 90, 115, 141, 166, 192, 218, 243 out
//    of 255). The Zone midpoints are the canonical tonal anchors used
//    by HighlightShadow's smoothstep windows, so shipping a sRGB helper
//    that deviates there would silently invalidate the HS contract.
//  - Known-value assertions at IEC-specified breakpoints:
//      * `gammaToLinear(0.04045) ≈ 0.00313` (piecewise transition)
//      * `linearToGamma(0.0031308) ≈ 0.04045` (inverse transition)
//      * `gammaToLinear(0.5) ≈ 0.2140` (mid gamma → Zone ≈ VI linear)
//      * `linearToGamma(0.5) ≈ 0.7354` (mid linear → high gamma)
//  - Piecewise continuity: the two branches must agree at the
//    breakpoint (no step).
//  - Non-negative input clamp.
//
//  These tests guard the canonical helpers that 8 shaders
//  (HighlightShadow, Clarity, Contrast, Blacks, Whites, WhiteBalance,
//  LUT3D, Exposure) all mirror — a regression here silently breaks
//  colour-space correctness across the entire filter stack.
//
//  References:
//    IEC 61966-2-1:1999 — default sRGB colour space spec
//    Wikipedia sRGB article (same formulas):
//      https://en.wikipedia.org/wiki/SRGB#Transfer_function_(%22gamma%22)
//    Norman Koren Simplified Zone System (midpoints used below):
//      https://www.normankoren.com/zonesystem.html
//

import XCTest
@testable import DCRenderKit
import Metal

final class SRGBGammaConversionTests: XCTestCase {

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

    /// Endpoints must pass exactly: 0 and 1 hit both branches' boundaries.
    func testRoundTripEndpoints() throws {
        try assertRoundTrip(c: 0.0, tolerance: 0.002)
        try assertRoundTrip(c: 1.0, tolerance: 0.002)
    }

    /// Every Zone System midpoint must survive the round trip — HS
    /// and Clarity's smoothstep windows are anchored here, so any drift
    /// silently breaks those contracts.
    ///
    /// 8-bit midpoints (from Norman Koren): 13, 38, 64, 90, 115, 141,
    /// 166, 192, 218, 243 / 255.
    func testRoundTripZoneMidpoints() throws {
        let midpoints: [Float] = [
            13.0 / 255, 38.0 / 255, 64.0 / 255, 90.0 / 255,
            115.0 / 255, 141.0 / 255, 166.0 / 255, 192.0 / 255,
            218.0 / 255, 243.0 / 255,
        ]
        for gamma in midpoints {
            // Convert to linear first (Zone midpoints are gamma-space
            // values) and round-trip the linear result.
            let linear = SRGBGammaSwiftReference.gammaToLinear(gamma)
            try assertRoundTrip(
                c: linear,
                tolerance: 0.003,
                label: "Zone gamma \(gamma)"
            )
        }
    }

    /// A scan across the input range catches drift anywhere between
    /// the endpoints.
    func testRoundTripLinearSweep() throws {
        for step in 0...20 {
            let x = Float(step) / 20.0
            try assertRoundTrip(c: x, tolerance: 0.003, label: "sweep \(x)")
        }
    }

    // MARK: - Known-value assertions (IEC 61966-2-1 canonical)

    /// Breakpoint: linear-space `c = 0.0031308` maps to gamma
    /// `0.04045` via the linear segment `12.92 · c`. Both branches
    /// must agree at this point (continuity).
    func testLinearToGammaAtBreakpoint() throws {
        let gamma = try linearToGamma(0.0031308)
        XCTAssertEqual(gamma, 0.04045, accuracy: 0.002,
                       "Breakpoint 0.0031308 should map to 0.04045")
    }

    /// Breakpoint (inverse): gamma `0.04045` maps to linear `0.0031308`.
    func testGammaToLinearAtBreakpoint() throws {
        let linear = try gammaToLinear(0.04045)
        XCTAssertEqual(linear, 0.0031308, accuracy: 0.0005,
                       "Breakpoint 0.04045 should map to 0.0031308")
    }

    /// Mid gamma `0.5` → linear `0.2140`. Hand-derived:
    ///   ((0.5 + 0.055) / 1.055)^2.4 = (0.5261)^2.4 ≈ 0.21404.
    /// Commonly cited reference value for display mid-grey.
    func testGammaToLinearAtMidGamma() throws {
        let linear = try gammaToLinear(0.5)
        XCTAssertEqual(linear, 0.2140, accuracy: 0.003)
    }

    /// Mid linear `0.5` → gamma `0.7354`. Hand-derived:
    ///   1.055 · 0.5^(1/2.4) − 0.055 = 1.055 · 0.7579 − 0.055 ≈ 0.7354.
    func testLinearToGammaAtMidLinear() throws {
        let gamma = try linearToGamma(0.5)
        XCTAssertEqual(gamma, 0.7354, accuracy: 0.003)
    }

    /// 8-bit 128/255 ≈ 0.5020 gamma → linear ≈ 0.2158.
    /// Important because 128/255 is the traditional "50 % grey"
    /// sample point in photo editing tools; a correct sRGB decode
    /// maps it to linear ≈ 21.6 %, not 50 %.
    func testGammaToLinear128() throws {
        let linear = try gammaToLinear(128.0 / 255.0)
        XCTAssertEqual(linear, 0.2158, accuracy: 0.003)
    }

    /// Zone V (8-bit 115/255 ≈ 0.4510 gamma) → linear ≈ 0.1691.
    /// Adam 18-percent reflectance card; ShotDeck mid-grey reference.
    func testGammaToLinearZoneV() throws {
        let linear = try gammaToLinear(115.0 / 255.0)
        XCTAssertEqual(linear, 0.1691, accuracy: 0.003)
    }

    // MARK: - Piecewise continuity

    /// Both branches meet at the breakpoint to within float precision.
    /// This is an IEC-guaranteed property, not an assumption — if the
    /// helpers ever drift by a step, something was rewritten wrong.
    func testPiecewiseContinuityLinearSide() throws {
        // Just inside each branch of the linearToGamma breakpoint.
        let below = try linearToGamma(0.0031308 - 1e-6)
        let above = try linearToGamma(0.0031308 + 1e-6)
        // Both should be ~0.04045.
        XCTAssertEqual(below, above, accuracy: 0.001,
                       "linearToGamma must be continuous at c=0.0031308")
        XCTAssertEqual(below, 0.04045, accuracy: 0.001)
    }

    func testPiecewiseContinuityGammaSide() throws {
        let below = try gammaToLinear(0.04045 - 1e-5)
        let above = try gammaToLinear(0.04045 + 1e-5)
        XCTAssertEqual(below, above, accuracy: 0.0005,
                       "gammaToLinear must be continuous at c=0.04045")
        XCTAssertEqual(below, 0.0031308, accuracy: 0.0005)
    }

    // MARK: - Non-negative clamp

    /// Negative inputs must be treated as zero (the sRGB curve is only
    /// defined for non-negative light).
    func testNegativeInputClampedToZero() throws {
        let gamma = try linearToGamma(-0.1)
        XCTAssertEqual(gamma, 0.0, accuracy: 0.002,
                       "linearToGamma(-0.1) must clamp to 0")
        let linear = try gammaToLinear(-0.1)
        XCTAssertEqual(linear, 0.0, accuracy: 0.002,
                       "gammaToLinear(-0.1) must clamp to 0")
    }

    // MARK: - Helpers

    private func assertRoundTrip(
        c: Float, tolerance: Float, label: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let source = try makeRGB16FSource(r: c, g: c, b: c)
        let output = try runFilter(source, filter: SRGBRoundTripFilter())
        let p = try readRGB(output)
        let labelSuffix = label.isEmpty ? "" : " (\(label))"
        XCTAssertEqual(p.r, c, accuracy: tolerance,
                       "R channel drift\(labelSuffix)", file: file, line: line)
        XCTAssertEqual(p.g, c, accuracy: tolerance,
                       "G channel drift\(labelSuffix)", file: file, line: line)
        XCTAssertEqual(p.b, c, accuracy: tolerance,
                       "B channel drift\(labelSuffix)", file: file, line: line)
    }

    /// Run the linearToGamma kernel on a uniform grey patch `c` and
    /// return the (channel-identical) output.
    private func linearToGamma(_ c: Float) throws -> Float {
        let source = try makeRGB16FSource(r: c, g: c, b: c)
        let output = try runFilter(source, filter: SRGBLinearToGammaFilter())
        return try readRGB(output).r
    }

    /// Run the gammaToLinear kernel on a uniform grey patch `c` and
    /// return the (channel-identical) output.
    private func gammaToLinear(_ c: Float) throws -> Float {
        let source = try makeRGB16FSource(r: c, g: c, b: c)
        let output = try runFilter(source, filter: SRGBGammaToLinearFilter())
        return try readRGB(output).r
    }

    private struct RGBPixel { var r: Float; var g: Float; var b: Float }

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

// MARK: - Swift mirror for assertion expected values

/// Independent Swift implementation of the same piecewise sRGB
/// formulas; used to derive expected values in tests without running
/// the shader. Matches IEC 61966-2-1 byte-for-byte.
private enum SRGBGammaSwiftReference {
    static func linearToGamma(_ c: Float) -> Float {
        let cc = max(c, 0)
        if cc <= 0.0031308 {
            return 12.92 * cc
        }
        return 1.055 * powf(cc, 1.0 / 2.4) - 0.055
    }

    static func gammaToLinear(_ c: Float) -> Float {
        let cc = max(c, 0)
        if cc <= 0.04045 {
            return cc / 12.92
        }
        return powf((cc + 0.055) / 1.055, 2.4)
    }
}

// MARK: - Test-only filter wrappers

/// Wraps the `DCRSRGBRoundTripTestKernel` as a `FilterProtocol`.
private struct SRGBRoundTripFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCRSRGBRoundTripTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}

/// Wraps the `DCRSRGBLinearToGammaTestKernel`.
private struct SRGBLinearToGammaFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCRSRGBLinearToGammaTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}

/// Wraps the `DCRSRGBGammaToLinearTestKernel`.
private struct SRGBGammaToLinearFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCRSRGBGammaToLinearTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}
