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
    //
    // ExposureFilter.metal shader contract:
    //   u.exposure ← slider / 100  (Swift → shader)
    //   exposure   ← clamp(u.exposure, -1, 1) * 0.7   (product compression)
    //   Positive branch (exposure > 0.001):
    //     gain   = 2^(exposure * 4.25)
    //     white² = (gain * 0.95)²
    //     linear = c^2.2
    //     gained = linear * gain
    //     mapped = gained * (1 + gained/white²) / (1 + gained)
    //     out    = mapped^(1/2.2)   (clamped to [0,1])
    //   Negative branch (exposure < -0.001):
    //     A = 0.270·|exposure|, γ = 1+|exposure|·2.49, B = 1-|exposure|·0.870
    //     out = clamp(A·c^γ + B·c, 0, 1)
    //
    // Tolerance reasoning: Float16 intermediate storage gives ~11-bit
    // mantissa (~3-4 decimal digits). Two nonlinear ops (pow + Reinhard)
    // accumulate ~0.02 absolute error vs float32 reference derivation.

    func testExposureIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.4, green: 0.5, blue: 0.6)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 0))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.4, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.5, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.6, accuracy: 0.01)
    }

    func testExposurePositiveFullSliderOnMidtoneMatchesReinhard() throws {
        // Derivation for slider=+100, c=0.5:
        //   exposure = 0.7
        //   gain = 2^(0.7 * 4.25) = 2^2.975 ≈ 7.86
        //   white² = (7.86 * 0.95)² ≈ 55.76
        //   linear = 0.5^2.2 ≈ 0.2176
        //   gained = 0.2176 * 7.86 ≈ 1.710
        //   mapped = 1.710 * (1 + 1.710/55.76) / (1 + 1.710) ≈ 0.650
        //   out = 0.650^(1/2.2) ≈ 0.822
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.822, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.822, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.822, accuracy: 0.02)
    }

    func testExposurePositiveHalfSliderOnMidtone() throws {
        // Derivation for slider=+50, c=0.5:
        //   exposure = 0.35, gain = 2^1.4875 ≈ 2.804
        //   white² = (2.804 * 0.95)² ≈ 7.094
        //   linear = 0.2176, gained ≈ 0.610
        //   mapped = 0.610 * 1.086 / 1.610 ≈ 0.412
        //   out = 0.412^0.4545 ≈ 0.668
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 50))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.668, accuracy: 0.02)
    }

    func testExposurePositiveFullSliderOnShadow() throws {
        // Derivation for slider=+100, c=0.3:
        //   gain = 7.86 (same), white² = 55.76
        //   linear = 0.3^2.2 ≈ 0.0707, gained ≈ 0.556
        //   mapped ≈ 0.556 * 1.010 / 1.556 ≈ 0.361
        //   out = 0.361^0.4545 ≈ 0.629
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.629, accuracy: 0.02)
    }

    func testExposureNegativeFullSliderOnMidHigh() throws {
        // Derivation for slider=-100, c=0.7:
        //   exposure = -0.7, absExp = 0.7
        //   A = 0.189, γ = 2.743, B = 0.391
        //   0.7^2.743 ≈ 0.376
        //   result = 0.189 * 0.376 + 0.391 * 0.7 ≈ 0.0710 + 0.2737 ≈ 0.345
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(source, filter: ExposureFilter(exposure: -100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.345, accuracy: 0.02)
    }

    func testExposureNegativeFullSliderOnShadow() throws {
        // Derivation for slider=-100, c=0.3:
        //   A=0.189, γ=2.743, B=0.391
        //   0.3^2.743 ≈ 0.0368
        //   result = 0.189 * 0.0368 + 0.391 * 0.3 ≈ 0.007 + 0.1173 ≈ 0.124
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(source, filter: ExposureFilter(exposure: -100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.124, accuracy: 0.02)
    }

    func testExposureMonotonicAcrossSliderRange() throws {
        // Exposure is monotonically increasing in slider for fixed input.
        // Walk -100, -50, 0, +50, +100 at c=0.5 and assert strict monotonicity.
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        var lastR: Float = -.infinity
        for slider: Float in [-100, -50, 0, 50, 100] {
            let output = try runSingle(source, filter: ExposureFilter(exposure: slider))
            let p = try readToneTexture(output)[4][4]
            XCTAssertGreaterThan(
                p.r, lastR,
                "Exposure must be monotonic in slider; slider=\(slider) produced r=\(p.r) ≤ prev=\(lastR)"
            )
            lastR = p.r
        }
    }

    func testExposurePositiveHighlightRolloffDoesNotHardClip() throws {
        // A pre-bright input (c=0.9) under +100 must NOT saturate exactly to
        // 1.0; Reinhard's compression is the whole point of using Extended
        // Reinhard instead of linear gain. If output hits 1.0 here, the
        // shader has either skipped the mapped/(1+gained) term or the
        // precision chain is truncating floats to 8-bit.
        //   gain = 7.86, white² = 55.76
        //   linear = 0.9^2.2 ≈ 0.7870
        //   gained ≈ 6.186
        //   mapped = 6.186 * (1 + 6.186/55.76) / (1 + 6.186)
        //          = 6.186 * 1.1109 / 7.186 ≈ 0.9564
        //   out = 0.9564^0.4545 ≈ 0.9799
        let source = try makeToneSource(red: 0.9, green: 0.9, blue: 0.9)
        let output = try runSingle(source, filter: ExposureFilter(exposure: 100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.980, accuracy: 0.02)
        XCTAssertLessThan(
            p.r, 0.995,
            "Reinhard rolloff must keep bright inputs under 1.0; got r=\(p.r) (suggests hard clipping)"
        )
    }

    // MARK: - Contrast
    //
    // ContrastFilter.metal shader contract:
    //   k     = (-0.356 * lumaMean + 2.289) * contrast
    //   pivot =  0.381 * lumaMean + 0.377
    //   y     = clamp(x + k·x·(1-x)·(x - pivot), 0, 1)
    // lumaMean clamped to [0.05, 0.95] inside the shader.

    func testContrastIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.42, green: 0.55, blue: 0.18)
        let output = try runSingle(source, filter: ContrastFilter(contrast: 0, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.42, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.55, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.18, accuracy: 0.01)
    }

    func testContrastPositiveFullSliderDarkensBelowPivot() throws {
        // Derivation for contrast=+100, lumaMean=0.5, x=0.3:
        //   k     = (-0.356·0.5 + 2.289)·1 = 2.111
        //   pivot = 0.381·0.5 + 0.377 = 0.5675
        //   y = 0.3 + 2.111·0.3·0.7·(0.3 - 0.5675)
        //     = 0.3 + 2.111·0.21·(-0.2675)
        //     = 0.3 - 0.1186
        //     ≈ 0.181
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(source, filter: ContrastFilter(contrast: 100, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.181, accuracy: 0.02)
    }

    func testContrastPositiveFullSliderBrightensAbovePivot() throws {
        // Derivation for contrast=+100, lumaMean=0.5, x=0.7:
        //   k=2.111, pivot=0.5675
        //   y = 0.7 + 2.111·0.7·0.3·(0.7 - 0.5675)
        //     = 0.7 + 2.111·0.21·0.1325
        //     = 0.7 + 0.0587
        //     ≈ 0.759
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(source, filter: ContrastFilter(contrast: 100, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.759, accuracy: 0.02)
    }

    func testContrastNegativeFullSliderLiftsDarkTowardPivot() throws {
        // Derivation for contrast=-100, lumaMean=0.5, x=0.3:
        //   k=-2.111, pivot=0.5675
        //   y = 0.3 + (-2.111)·0.3·0.7·(0.3 - 0.5675)
        //     = 0.3 + (-2.111)·0.21·(-0.2675)
        //     = 0.3 + 0.1186
        //     ≈ 0.419
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(source, filter: ContrastFilter(contrast: -100, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.419, accuracy: 0.02)
    }

    func testContrastLumaMeanClampingAtExtremes() throws {
        // lumaMean is clamped to [0.05, 0.95] inside the shader. Feeding
        // 0.01 must produce the same output as 0.05 (and 0.99 == 0.95).
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)

        let clampedLow = try runSingle(
            source, filter: ContrastFilter(contrast: 100, lumaMean: 0.01)
        )
        let lowEdge = try runSingle(
            source, filter: ContrastFilter(contrast: 100, lumaMean: 0.05)
        )
        let lowP = try readToneTexture(clampedLow)[4][4]
        let edgeP = try readToneTexture(lowEdge)[4][4]
        XCTAssertEqual(lowP.r, edgeP.r, accuracy: 1e-3, "lumaMean<0.05 must clamp to 0.05")

        let clampedHigh = try runSingle(
            source, filter: ContrastFilter(contrast: 100, lumaMean: 0.99)
        )
        let highEdge = try runSingle(
            source, filter: ContrastFilter(contrast: 100, lumaMean: 0.95)
        )
        let highP = try readToneTexture(clampedHigh)[4][4]
        let highEdgeP = try readToneTexture(highEdge)[4][4]
        XCTAssertEqual(highP.r, highEdgeP.r, accuracy: 1e-3, "lumaMean>0.95 must clamp to 0.95")
    }

    // MARK: - Whites
    //
    // WhitesFilter.metal shader contract:
    //   Positive: y = x·(1 + k·x·(1-x)^b) where k = k100·t, t = whites ∈ [0, 1]
    //   Negative: luma-ratio path with k_neg = -0.1995·t, a = 1.4628, b = 0.2094
    //
    // LUT anchors (WhitesFilter.swift lutMeans/lutK100/lutB):
    //   lumaMean=0.2877 → k100=2.3215, b=1.3881
    //   lumaMean=0.3995 → k100=5.4223, b=1.9729
    //   lumaMean=0.6004 → k100=0.6251, b=0.9875

    func testWhitesIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.6, green: 0.3, blue: 0.9)
        let output = try runSingle(source, filter: WhitesFilter(whites: 0, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.6, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.3, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.9, accuracy: 0.01)
    }

    func testWhitesPositiveFullSliderLowLumaMeanAnchor() throws {
        // Derivation for whites=+100, lumaMean=0.2877 (anchor 0), x=0.7:
        //   k100=2.3215, b=1.3881, t=1.0, k=2.3215
        //   (1-0.7)^1.3881 = 0.3^1.3881 = exp(1.3881·ln(0.3)) = exp(-1.672) ≈ 0.188
        //   y = 0.7 · (1 + 2.3215·0.7·0.188) = 0.7 · 1.3056 ≈ 0.914
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(source, filter: WhitesFilter(whites: 100, lumaMean: 0.2877))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.914, accuracy: 0.03)
    }

    func testWhitesPositiveFullSliderBrightRegion() throws {
        // Derivation for whites=+100, lumaMean=0.2877, x=0.9:
        //   k=2.3215, b=1.3881
        //   (0.1)^1.3881 = exp(1.3881·ln(0.1)) = exp(-3.196) ≈ 0.0408
        //   y = 0.9 · (1 + 2.3215·0.9·0.0408) = 0.9 · 1.0853 ≈ 0.977
        let source = try makeToneSource(red: 0.9, green: 0.9, blue: 0.9)
        let output = try runSingle(source, filter: WhitesFilter(whites: 100, lumaMean: 0.2877))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.977, accuracy: 0.02)
    }

    func testWhitesNegativeFullSliderGrayDarkens() throws {
        // Derivation for whites=-100, uniform gray x=0.7:
        //   t = 1.0, k_neg = -0.1995
        //   luma = 0.7 (Rec.709 on uniform = input)
        //   0.7^1.4628 = exp(1.4628·ln(0.7)) = exp(-0.522) ≈ 0.593
        //   0.3^0.2094 = exp(0.2094·ln(0.3)) = exp(-0.252) ≈ 0.777
        //   y = 0.7·(1 + (-0.1995)·0.593·0.777)
        //     = 0.7·(1 - 0.0919) = 0.7·0.9081 ≈ 0.636
        //   ratio = y / luma = 0.908 → each channel = 0.7·0.908 = 0.636
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(source, filter: WhitesFilter(whites: -100, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.636, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.636, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.636, accuracy: 0.02)
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
    //
    // BlacksFilter.metal shader contract:
    //   y = x · (1 + k · (1-x)^a)
    //   Positive: k = 0.6312·t, a = 2.1857
    //   Negative: k = -1.5515·t, a = 2.3236

    func testBlacksIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.15, green: 0.35, blue: 0.55)
        let output = try runSingle(source, filter: BlacksFilter(blacks: 0))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.15, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.35, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.55, accuracy: 0.01)
    }

    func testBlacksPositiveFullSliderOnDeepShadow() throws {
        // Derivation for blacks=+100, x=0.1:
        //   k=0.6312, a=2.1857
        //   (1-0.1)^2.1857 = 0.9^2.1857 = exp(2.1857·ln(0.9)) = exp(-0.230) ≈ 0.795
        //   y = 0.1·(1 + 0.6312·0.795) = 0.1·1.5018 ≈ 0.150
        let source = try makeToneSource(red: 0.1, green: 0.1, blue: 0.1)
        let output = try runSingle(source, filter: BlacksFilter(blacks: 100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.150, accuracy: 0.02)
    }

    func testBlacksPositiveFullSliderOnMidtone() throws {
        // Derivation for blacks=+100, x=0.5:
        //   (0.5)^2.1857 = exp(2.1857·ln(0.5)) = exp(-1.515) ≈ 0.220
        //   y = 0.5·(1 + 0.6312·0.220) = 0.5·1.1389 ≈ 0.569
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(source, filter: BlacksFilter(blacks: 100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.569, accuracy: 0.02)
    }

    func testBlacksNegativeFullSliderCrushesShadow() throws {
        // Derivation for blacks=-100, x=0.2:
        //   k=-1.5515, a=2.3236
        //   (0.8)^2.3236 = exp(2.3236·ln(0.8)) = exp(-0.518) ≈ 0.596
        //   y = 0.2·(1 + (-1.5515)·0.596) = 0.2·(1 - 0.924) = 0.2·0.076 ≈ 0.015
        let source = try makeToneSource(red: 0.2, green: 0.2, blue: 0.2)
        let output = try runSingle(source, filter: BlacksFilter(blacks: -100))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.015, accuracy: 0.02)
    }

    func testBlacksMonotonicInSliderForShadow() throws {
        // For a fixed shadow input (0.15), sweeping slider -100 → +100 must
        // produce strictly monotonic output (crush → identity → lift).
        let source = try makeToneSource(red: 0.15, green: 0.15, blue: 0.15)
        var last: Float = -.infinity
        for slider: Float in [-100, -50, 0, 50, 100] {
            let output = try runSingle(source, filter: BlacksFilter(blacks: slider))
            let p = try readToneTexture(output)[4][4]
            XCTAssertGreaterThan(
                p.r, last,
                "Blacks must be monotonic in slider; slider=\(slider) produced r=\(p.r) ≤ prev=\(last)"
            )
            last = p.r
        }
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
