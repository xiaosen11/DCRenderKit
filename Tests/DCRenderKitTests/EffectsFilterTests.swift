//
//  EffectsFilterTests.swift
//  DCRenderKitTests
//
//  Identity + extreme tests for Batch 2: Sharpen / FilmGrain / CCD / LUT3D.
//

import XCTest
@testable import DCRenderKit
import Metal

final class EffectsFilterTests: XCTestCase {

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

    // MARK: - Sharpen
    //
    // SharpenFilter.metal shader contract:
    //   sharpened = center · (1 + 4·u.amount) - (L + R + T + B) · u.amount
    // SharpenFilter.swift contract:
    //   u.amount = (sliderAmount / 100) · 1.6        ← product compression
    //   So slider=100 → shader amount = 1.6 (the perceptual "strong" peak).
    //
    // Properties exploited:
    //   - Laplacian on constant f(x,y) = k   → Δf = 0 → sharpen = identity
    //   - Laplacian on linear   f(x,y) = ax+b → Δf = 0 → sharpen = identity (interior)
    //   - Laplacian on step                   → ±overshoot computable precisely

    func testSharpenIdentityAtZero() throws {
        let source = try makeEffectSource(red: 0.4, green: 0.4, blue: 0.4)
        let output = try runSingle(source, filter: SharpenFilter(amount: 0, step: 1))
        let p = try readEffectTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.4, accuracy: 0.01)
    }

    func testSharpenOnUniformPatchIsIdentityAtMaxSlider() throws {
        // Laplacian of a constant function is zero — uniform input must pass
        // through unchanged even at the strongest slider setting (100).
        // If the kernel weights are wrong (e.g. center mul is `4s` instead
        // of `1 + 4s`), this test fails catastrophically.
        let source = try makeEffectSource(red: 0.4, green: 0.4, blue: 0.4, width: 16, height: 16)
        let output = try runSingle(source, filter: SharpenFilter(amount: 100, step: 1))
        let p = try readEffectTexture(output)[8][8]
        XCTAssertEqual(
            p.r, 0.4, accuracy: 0.02,
            "Uniform patch under sharpen must be identity at slider=100; got r=\(p.r)"
        )
    }

    func testSharpenOnLinearRampIsIdentityAtInteriorAtMaxSlider() throws {
        // Laplacian of a linear gradient is zero. Interior pixels must pass
        // through unchanged even at the strongest slider. Boundary pixels
        // (x=0 and x=15) sample clamped neighbors that break linearity — so
        // we only check interior x∈[2,13].
        let source = try makeRampSource()  // horizontal 0→1 ramp, 16×16
        let output = try runSingle(source, filter: SharpenFilter(amount: 100, step: 1))
        let pixels = try readEffectTexture(output)
        for x in 2...13 {
            let expected = Float(x) / 15.0
            XCTAssertEqual(
                pixels[8][x].r, expected, accuracy: 0.03,
                "Linear ramp interior x=\(x) must sharpen to identity at slider=100; got r=\(pixels[8][x].r) expected=\(expected)"
            )
        }
    }

    func testSharpenOnStepEdgeOvershootsPredictably() throws {
        // Derivation for slider=100 → u.amount = (100/100)·1.6 = 1.6:
        //   centerMul = 1 + 4·1.6 = 7.4
        // Step source: columns 0…7 = 0.4, columns 8…15 = 0.6.
        // At column 7 (last dark column):
        //   center=0.4, left=0.4, right=0.6, top=0.4, bot=0.4
        //   Σneighbors = 0.4 + 0.6 + 0.4 + 0.4 = 1.8
        //   y = 0.4·7.4 − 1.8·1.6 = 2.96 − 2.88 = 0.08
        // At column 8 (first bright column):
        //   center=0.6, left=0.4, right=0.6, top=0.6, bot=0.6
        //   Σneighbors = 0.4 + 0.6 + 0.6 + 0.6 = 2.2
        //   y = 0.6·7.4 − 2.2·1.6 = 4.44 − 3.52 = 0.92
        let source = try makeStepEdgeSource(darkValue: 0.4, brightValue: 0.6, width: 16, height: 16)
        let output = try runSingle(source, filter: SharpenFilter(amount: 100, step: 1))
        let pixels = try readEffectTexture(output)

        XCTAssertEqual(pixels[8][7].r, 0.08, accuracy: 0.03, "Dark side of edge must undershoot to 0.08")
        XCTAssertEqual(pixels[8][8].r, 0.92, accuracy: 0.03, "Bright side of edge must overshoot to 0.92")
    }

    // MARK: - FilmGrain

    func testFilmGrainIdentityAtZeroDensity() throws {
        let source = try makeEffectSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source,
            filter: FilmGrainFilter(density: 0, roughness: 0.5, chromaticity: 0.5, grainSize: 4)
        )
        let p = try readEffectTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.5, accuracy: 0.01)
    }

    func testFilmGrainExtremeStayFinite() throws {
        let source = try makeEffectSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source,
            filter: FilmGrainFilter(density: 1.0, roughness: 1.0, chromaticity: 1.0, grainSize: 4)
        )
        let pixels = try readEffectTexture(output)
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                XCTAssertTrue(p.g.isFinite)
                XCTAssertTrue(p.b.isFinite)
            }
        }
    }

    func testFilmGrainProducesVisibleNoiseAtExtreme() throws {
        // A mid-gray source. With density = 1, grain must deviate from 0.5.
        let source = try makeEffectSource(red: 0.5, green: 0.5, blue: 0.5, width: 32, height: 32)
        let output = try runSingle(
            source,
            filter: FilmGrainFilter(density: 1.0, roughness: 0.5, chromaticity: 0, grainSize: 4)
        )
        let pixels = try readEffectTexture(output)

        // Expect at least one pixel outside the ±0.005 identity band.
        let hasDeviation = pixels.contains { row in
            row.contains { abs($0.r - 0.5) > 0.005 }
        }
        XCTAssertTrue(hasDeviation, "FilmGrain density=1 should produce visible noise")
    }

    // MARK: - CCD

    func testCCDIdentityAtZeroStrength() throws {
        let source = try makeEffectSource(red: 0.3, green: 0.5, blue: 0.7)
        let output = try runSingle(
            source,
            filter: CCDFilter(strength: 0)
        )
        let p = try readEffectTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.3, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.7, accuracy: 0.01)
    }

    func testCCDExtremeClampsAndStayFinite() throws {
        let source = try makeRampSource()
        let output = try runSingle(
            source,
            filter: CCDFilter(
                strength: 100,
                digitalNoise: 100,
                chromaticAberration: 100,
                sharpening: 100,
                saturationBoost: 100
            )
        )
        let pixels = try readEffectTexture(output)
        for row in pixels {
            for p in row {
                XCTAssertTrue(p.r.isFinite)
                XCTAssertTrue(p.g.isFinite)
                XCTAssertTrue(p.b.isFinite)
                XCTAssertGreaterThanOrEqual(p.r, -1e-3)
                XCTAssertLessThanOrEqual(p.r, 1.0 + 1e-3)
            }
        }
    }

    // MARK: - LUT3D

    func testLUT3DIdentityLUTPreservesColor() throws {
        // A 3×3×3 identity cube where lut(r,g,b) = (r,g,b).
        let lut = try LUT3DFilter(
            cubeData: Self.identityLUTData(dimension: 3),
            dimension: 3,
            intensity: 1.0,
            colorSpace: .perceptual,
            device: device
        )

        let source = try makeEffectSource(red: 0.3, green: 0.5, blue: 0.7, width: 16, height: 16)
        let output = try runSingle(source, filter: lut)
        let p = try readEffectTexture(output)[8][8]

        // Identity LUT + trilinear. Tolerance absorbs the dither ±1/255.
        XCTAssertEqual(p.r, 0.3, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.7, accuracy: 0.02)
    }

    func testLUT3DIdentityLUTLinearModePreservesColorViaWrap() throws {
        // In .linear mode, an identity LUT must still pass the color
        // through unchanged. The shader un-linearizes input to gamma,
        // looks up identity cube (gamma→gamma), re-linearizes output,
        // and mixes at intensity=1.0. For identity cube, the round-trip
        // should yield the original linear value within pow-approximation
        // noise (≈ 2% for mid-values, larger at the tails).
        let lut = try LUT3DFilter(
            cubeData: Self.identityLUTData(dimension: 17),
            dimension: 17,
            intensity: 1.0,
            colorSpace: .linear,
            device: device
        )

        let source = try makeEffectSource(red: 0.4, green: 0.4, blue: 0.4, width: 16, height: 16)
        let output = try runSingle(source, filter: lut)
        let p = try readEffectTexture(output)[8][8]
        XCTAssertEqual(p.r, 0.4, accuracy: 0.03)
        XCTAssertEqual(p.g, 0.4, accuracy: 0.03)
        XCTAssertEqual(p.b, 0.4, accuracy: 0.03)
    }

    func testLUT3DLinearModeMatchesPerceptualOnSolidColorCube() throws {
        // Parity: a solid-color cube (everything → red) should produce the
        // same final color regardless of color-space mode, because the
        // cube output is gamma-space; linear mode linearizes it back to
        // the linear equivalent red before mixing. A 0.5 gamma source in
        // gamma mode and the linearized-equivalent 0.5^2.2 ≈ 0.217 source
        // in linear mode must produce visually identical output once both
        // are viewed in the same space.
        let redGamma = try LUT3DFilter(
            cubeData: Self.solidColorLUTData(dimension: 3, r: 1.0, g: 0.0, b: 0.0),
            dimension: 3,
            intensity: 1.0,
            colorSpace: .perceptual,
            device: device
        )
        let redLinear = try LUT3DFilter(
            cubeData: Self.solidColorLUTData(dimension: 3, r: 1.0, g: 0.0, b: 0.0),
            dimension: 3,
            intensity: 1.0,
            colorSpace: .linear,
            device: device
        )

        let sourceGamma = try makeEffectSource(red: 0.5, green: 0.5, blue: 0.5)
        let sourceLinear = try makeEffectSource(
            red: powf(0.5, 2.2), green: powf(0.5, 2.2), blue: powf(0.5, 2.2)
        )

        let gOut = try runSingle(sourceGamma, filter: redGamma)
        let lOut = try runSingle(sourceLinear, filter: redLinear)
        let pg = try readEffectTexture(gOut)[4][4]
        let pl = try readEffectTexture(lOut)[4][4]

        // Perceptual path: intensity=1 → lutColor = (1,0,0); output = (1,0,0).
        XCTAssertEqual(pg.r, 1.0, accuracy: 0.03)
        XCTAssertEqual(pg.g, 0.0, accuracy: 0.03)
        // Linear path: lutColor = (1,0,0) gamma → (1,0,0) linear → output = (1,0,0).
        XCTAssertEqual(pl.r, 1.0, accuracy: 0.03)
        XCTAssertEqual(pl.g, 0.0, accuracy: 0.03)
    }

    func testLUT3DIntensityZeroBypassesLUT() throws {
        // Even a "destructive" LUT (everything → red) produces identity at
        // intensity=0, because the shader does mix(src, lut, 0) = src.
        let redLUT = try LUT3DFilter(
            cubeData: Self.solidColorLUTData(dimension: 3, r: 1, g: 0, b: 0),
            dimension: 3,
            intensity: 0.0,
            colorSpace: .perceptual,
            device: device
        )

        let source = try makeEffectSource(red: 0.2, green: 0.6, blue: 0.9)
        let output = try runSingle(source, filter: redLUT)
        let p = try readEffectTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.2, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.6, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.9, accuracy: 0.02)
    }

    func testLUT3DCubeParserAcceptsStandardHeader() {
        let cube = """
        TITLE "test"
        # comment line
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let parsed = CubeFileParser.parse(string: cube)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.dimension, 2)
        // 2^3 = 8 entries × 4 floats × 4 bytes = 128 bytes
        XCTAssertEqual(parsed?.data.count, 128)
    }

    func testLUT3DCubeParserRejectsMalformed() {
        // Missing LUT_3D_SIZE.
        XCTAssertNil(CubeFileParser.parse(string: "TITLE \"bad\"\n0 0 0\n1 1 1\n"))
        // Truncated data (claims dimension 2 but only 3 data rows).
        XCTAssertNil(CubeFileParser.parse(string: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n"))
    }

    func testLUT3DThrowsOnInvalidDataCount() {
        let badData = Data(count: 5)  // far short of 3^3 * 16 = 432 bytes
        XCTAssertThrowsError(
            try LUT3DFilter(cubeData: badData, dimension: 3, device: device)
        ) { error in
            guard case PipelineError.texture(.textureCreationFailed) = error else {
                return XCTFail("Expected texture creation error, got \(error)")
            }
        }
    }

    // MARK: - Fuse groups

    func testEffectFiltersDeclareNoFuseGroup() {
        XCTAssertNil(SharpenFilter.fuseGroup)
        XCTAssertNil(FilmGrainFilter.fuseGroup)
        XCTAssertNil(CCDFilter.fuseGroup)
        XCTAssertNil(LUT3DFilter.fuseGroup)
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

    // MARK: - LUT data helpers

    /// Build an identity cube as tightly-packed RGBA Float32 bytes.
    /// For `dim=N`, entry (i,j,k) maps to color (i/(N-1), j/(N-1), k/(N-1)).
    static func identityLUTData(dimension: Int) -> Data {
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

    /// Build a cube that maps every input color to a single solid RGB value.
    static func solidColorLUTData(dimension: Int, r: Float, g: Float, b: Float) -> Data {
        var rgba: [Float] = []
        rgba.reserveCapacity(dimension * dimension * dimension * 4)
        for _ in 0..<(dimension * dimension * dimension) {
            rgba.append(r)
            rgba.append(g)
            rgba.append(b)
            rgba.append(1.0)
        }
        return rgba.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Private test utilities

private struct EffectPixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeEffectSource(
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

/// A step-edge source: left half = `darkValue`, right half = `brightValue`.
/// Edge is between column (width/2 - 1) and column (width/2). Useful for
/// verifying neighbor-sampling filters' overshoot / undershoot math.
private func makeStepEdgeSource(
    darkValue: Float, brightValue: Float,
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
    let hDark = Float16(darkValue).bitPattern
    let hBright = Float16(brightValue).bitPattern
    let ha = Float16(1.0).bitPattern
    let midCol = width / 2
    for y in 0..<height {
        for x in 0..<width {
            let h = x < midCol ? hDark : hBright
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

/// A 16×16 horizontal luma ramp from 0 to 1 — useful for exercising
/// neighbor-sampling filters at interior pixels.
private func makeRampSource() throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let width = 16
    let height = 16
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

private func readEffectTexture(_ texture: MTLTexture) throws -> [[EffectPixel]] {
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
    var result: [[EffectPixel]] = []
    for y in 0..<height {
        var row: [EffectPixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(EffectPixel(
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
