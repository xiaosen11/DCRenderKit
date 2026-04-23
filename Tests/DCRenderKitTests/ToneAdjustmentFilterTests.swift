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
        // Derivation is for the perceptual-space shader branch:
        //   exposure = 0.7, gain = 2^(0.7 * 4.25) = 2^2.975 ≈ 7.86
        //   white² = (7.86 * 0.95)² ≈ 55.76
        //   linear = 0.5^2.2 ≈ 0.2176         ← pow(,2.2) INSIDE shader
        //   gained = 0.2176 * 7.86 ≈ 1.710
        //   mapped = 1.710 * (1 + 1.710/55.76) / (1 + 1.710) ≈ 0.650
        //   out = 0.650^(1/2.2) ≈ 0.822       ← pow(,1/2.2) INSIDE shader
        // Explicitly selecting `.perceptual` because this derivation is
        // only valid for that branch; see `Exposure.linear` tests below
        // for the linear-branch variant.
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: 100, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.822, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.822, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.822, accuracy: 0.02)
    }

    func testExposurePositiveHalfSliderOnMidtone() throws {
        // Perceptual-branch derivation for slider=+50, c=0.5:
        //   exposure = 0.35, gain ≈ 2.804
        //   white² ≈ 7.094, linear = 0.2176, gained ≈ 0.610
        //   mapped ≈ 0.610 * 1.086 / 1.610 ≈ 0.412
        //   out = 0.412^0.4545 ≈ 0.668
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: 50, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.668, accuracy: 0.02)
    }

    func testExposurePositiveFullSliderOnShadow() throws {
        // Perceptual-branch derivation for slider=+100, c=0.3:
        //   gain = 7.86, white² = 55.76
        //   linear = 0.3^2.2 ≈ 0.0707, gained ≈ 0.556
        //   mapped ≈ 0.556 * 1.010 / 1.556 ≈ 0.361
        //   out = 0.361^0.4545 ≈ 0.629
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: 100, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.629, accuracy: 0.02)
    }

    // MARK: Exposure — linear-space branch
    //
    // Linear branch skips the internal pow(,2.2) / pow(,1/2.2) conversions
    // and runs Reinhard on the input values directly. Input values are
    // whatever the texture carries — in these tests Float16 values written
    // to rgba16Float intermediates, treated by the shader as "already linear".

    func testExposureLinearSpaceBranchBrighterThanPerceptualForSameSlider() throws {
        // For the same (slider, input) pair the linear branch produces a
        // brighter output than the perceptual branch, because it treats
        // the gamma-encoded 0.5 as if it were already 0.5-linear (which
        // is a much brighter physical value than pow(0.5, 2.2) ≈ 0.2176).
        //
        // Derivation for slider=+100, c=0.5, linear branch:
        //   gain = 7.86, white² = 55.76
        //   gained = 0.5 * 7.86 = 3.93
        //   mapped = 3.93 * (1 + 3.93/55.76) / (1 + 3.93)
        //          = 3.93 * 1.0705 / 4.93 ≈ 0.853
        //   out = 0.853 (no pow back)
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: 100, colorSpace: .linear)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.853, accuracy: 0.02)
        XCTAssertGreaterThan(
            p.r, 0.822 + 0.01,
            "Linear branch must brighten more than perceptual branch at slider=+100"
        )
    }

    func testExposureLinearSpaceBranchIdentityAtZero() throws {
        // Dead-zone short-circuit must hold in linear mode too.
        let source = try makeToneSource(red: 0.42, green: 0.55, blue: 0.18)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: 0, colorSpace: .linear)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.42, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.55, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.18, accuracy: 0.01)
    }

    func testExposureLinearVsPerceptualDifferForPositiveSlider() throws {
        // Branch divergence proof: same filter, different colorSpace,
        // different pixel output. Guards against a future refactor that
        // accidentally collapses both branches into one.
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let perceptualOut = try runSingle(
            source, filter: ExposureFilter(exposure: 100, colorSpace: .perceptual)
        )
        let linearOut = try runSingle(
            source, filter: ExposureFilter(exposure: 100, colorSpace: .linear)
        )
        let pp = try readToneTexture(perceptualOut)[4][4]
        let pl = try readToneTexture(linearOut)[4][4]
        XCTAssertGreaterThan(
            abs(pp.r - pl.r), 0.02,
            "Perceptual vs linear must produce visibly different output"
        )
    }

    func testExposureNegativeBranchLinearMatchesPerceptualViaGammaWrap() throws {
        // After the negative branch also wraps with linearize/delinearize,
        // the two modes produce numerically different outputs but the
        // gamma-space equivalents match (visual parity).
        let gammaX: Float = 0.7
        let sourceGamma = try makeToneSource(red: gammaX, green: gammaX, blue: gammaX)
        let sourceLinear = try makeToneSource(
            red: powf(gammaX, 2.2), green: powf(gammaX, 2.2), blue: powf(gammaX, 2.2)
        )
        let pOut = try runSingle(
            sourceGamma, filter: ExposureFilter(exposure: -100, colorSpace: .perceptual)
        )
        let lOut = try runSingle(
            sourceLinear, filter: ExposureFilter(exposure: -100, colorSpace: .linear)
        )
        let yp = try readToneTexture(pOut)[4][4].r
        let yl = try readToneTexture(lOut)[4][4].r
        let ylAsGamma = powf(max(yl, 0), 1.0 / 2.2)
        XCTAssertEqual(
            ylAsGamma, yp, accuracy: 0.03,
            "Exposure negative linear → re-gamma must match perceptual; got \(ylAsGamma) vs \(yp)"
        )
    }

    func testExposureNegativeFullSliderOnMidHigh() throws {
        // Perceptual branch. slider=-100, c=0.7:
        //   A = 0.189, γ = 2.743, B = 0.391
        //   result ≈ 0.189·0.376 + 0.391·0.7 ≈ 0.345
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: -100, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.345, accuracy: 0.02)
    }

    func testExposureNegativeFullSliderOnShadow() throws {
        // Perceptual branch. slider=-100, c=0.3: result ≈ 0.124.
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(
            source, filter: ExposureFilter(exposure: -100, colorSpace: .perceptual)
        )
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
    // ContrastFilter.metal shader contract (DaVinci log-space slope):
    //   pivot clamped to [0.05, 0.95] in the shader
    //   slope = exp2(contrast · 1.585)   → slider ±1 ⇒ slope ∈ {1/3, 3}
    //   y = clamp(pivot · (x / pivot)^slope, 0, 1)

    func testContrastIdentityAtZero() throws {
        let source = try makeToneSource(red: 0.42, green: 0.55, blue: 0.18)
        let output = try runSingle(source, filter: ContrastFilter(contrast: 0, lumaMean: 0.5))
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.42, accuracy: 0.01)
        XCTAssertEqual(p.g, 0.55, accuracy: 0.01)
        XCTAssertEqual(p.b, 0.18, accuracy: 0.01)
    }

    func testContrastPositiveFullSliderDarkensBelowPivot() throws {
        // Perceptual-branch derivation for contrast=+100, lumaMean=0.5, x=0.3:
        //   slope = exp2(+1 · 1.585) ≈ 3.0
        //   ratio = 0.3 / 0.5 = 0.6
        //   y = 0.5 · 0.6^3 = 0.5 · 0.216 = 0.108
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(
            source,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.5, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.108, accuracy: 0.02)
    }

    func testContrastPositiveFullSliderBrightensAbovePivot() throws {
        // x=0.6 (was 0.7): at slider=+100 with pivot=0.5 and slope=3,
        //   x=0.7 ⇒ y = 0.5 · 1.4^3 = 1.372 → clamps to 1.0, so the
        // assertion would only prove the clamp, not the brighten shape.
        // x=0.6 ⇒ ratio 1.2, stays in-gamut:
        //   y = 0.5 · 1.2^3 = 0.5 · 1.728 = 0.864
        let source = try makeToneSource(red: 0.6, green: 0.6, blue: 0.6)
        let output = try runSingle(
            source,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.5, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.864, accuracy: 0.02)
    }

    func testContrastNegativeFullSliderLiftsDarkTowardPivot() throws {
        // contrast=-100, pivot=0.5, slope = exp2(-1.585) = 1/3:
        //   ratio = 0.6, 0.6^(1/3) ≈ 0.8434
        //   y = 0.5 · 0.8434 ≈ 0.422
        let source = try makeToneSource(red: 0.3, green: 0.3, blue: 0.3)
        let output = try runSingle(
            source,
            filter: ContrastFilter(contrast: -100, lumaMean: 0.5, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.422, accuracy: 0.02)
    }

    func testContrastLumaMeanClampingAtExtremes() throws {
        // lumaMean is clamped to [0.05, 0.95] inside the shader. Feeding
        // 0.01 must produce the same output as 0.05 (and 0.99 == 0.95).
        // Perceptual branch to avoid the linear-to-gamma lumaMean warp.
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)

        let clampedLow = try runSingle(
            source,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.01, colorSpace: .perceptual)
        )
        let lowEdge = try runSingle(
            source,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.05, colorSpace: .perceptual)
        )
        let lowP = try readToneTexture(clampedLow)[4][4]
        let edgeP = try readToneTexture(lowEdge)[4][4]
        XCTAssertEqual(lowP.r, edgeP.r, accuracy: 1e-3, "lumaMean<0.05 must clamp to 0.05")

        let clampedHigh = try runSingle(
            source,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.99, colorSpace: .perceptual)
        )
        let highEdge = try runSingle(
            source,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.95, colorSpace: .perceptual)
        )
        let highP = try readToneTexture(clampedHigh)[4][4]
        let highEdgeP = try readToneTexture(highEdge)[4][4]
        XCTAssertEqual(highP.r, highEdgeP.r, accuracy: 1e-3, "lumaMean>0.95 must clamp to 0.95")
    }

    func testContrastLinearModeMatchesPerceptualViaGammaWrap() throws {
        // Parity proof: linear mode's pow-wrap must produce output that
        // equals the perceptual output when both are mapped to the same
        // color space. Pipeline: feed a gamma value x_g. In perceptual
        // mode the output is y_p (gamma). In linear mode the input is
        // srgbToLinear(x_g) and the output is y_l (linear). The invariant
        // is: linearToGamma(y_l) ≈ y_p, i.e. pow(y_l, 1/2.2) ≈ y_p.
        //
        // Because our `makeToneSource` just writes bit patterns with no
        // color-space tagging, we can simulate both paths by feeding the
        // same numerical source to each filter instance, and comparing
        // pow(y_l, 1/2.2) to y_p directly. A tight match proves the
        // linear branch's wrap is correctly derived.
        let gammaX: Float = 0.5
        let sourceGamma = try makeToneSource(red: gammaX, green: gammaX, blue: gammaX)
        let sourceLinear = try makeToneSource(
            red: powf(gammaX, 2.2), green: powf(gammaX, 2.2), blue: powf(gammaX, 2.2)
        )

        let perceptualOut = try runSingle(
            sourceGamma,
            filter: ContrastFilter(contrast: 100, lumaMean: 0.5, colorSpace: .perceptual)
        )
        let linearOut = try runSingle(
            sourceLinear,
            filter: ContrastFilter(contrast: 100, lumaMean: powf(0.5, 2.2), colorSpace: .linear)
        )

        let yp = try readToneTexture(perceptualOut)[4][4].r
        let yl = try readToneTexture(linearOut)[4][4].r
        let ylAsGamma = powf(max(yl, 0), 1.0 / 2.2)

        XCTAssertEqual(
            ylAsGamma, yp, accuracy: 0.03,
            "Linear-mode output re-gammad must match perceptual output (parity). got linear≈\(ylAsGamma), perceptual=\(yp)"
        )
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
        // Perceptual branch, LUT anchor 0 (lumaMean=0.2877, k100=2.3215, b=1.3881).
        //   (0.3)^1.3881 ≈ 0.188
        //   y = 0.7·(1 + 2.3215·0.7·0.188) ≈ 0.914
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(
            source,
            filter: WhitesFilter(whites: 100, lumaMean: 0.2877, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.914, accuracy: 0.03)
    }

    func testWhitesPositiveFullSliderBrightRegion() throws {
        // Perceptual branch. (0.1)^1.3881 ≈ 0.0408; y ≈ 0.977.
        let source = try makeToneSource(red: 0.9, green: 0.9, blue: 0.9)
        let output = try runSingle(
            source,
            filter: WhitesFilter(whites: 100, lumaMean: 0.2877, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.977, accuracy: 0.02)
    }

    func testWhitesNegativeFullSliderGrayDarkens() throws {
        // Perceptual branch. Luma-ratio on uniform 0.7 gray:
        //   0.7^1.4628 ≈ 0.593; 0.3^0.2094 ≈ 0.777
        //   y ≈ 0.7·(1 - 0.0919) ≈ 0.636
        let source = try makeToneSource(red: 0.7, green: 0.7, blue: 0.7)
        let output = try runSingle(
            source,
            filter: WhitesFilter(whites: -100, lumaMean: 0.5, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.636, accuracy: 0.02)
        XCTAssertEqual(p.g, 0.636, accuracy: 0.02)
        XCTAssertEqual(p.b, 0.636, accuracy: 0.02)
    }

    func testWhitesLinearPositiveMatchesPerceptualViaGammaWrap() throws {
        // Parity for Whites positive branch. lumaMean in perceptual mode
        // is a gamma-space value (0.2877); the equivalent in linear mode
        // is srgbToLinear(0.2877) = 0.2877^2.2 ≈ 0.0665.
        let gammaX: Float = 0.7
        let gammaLumaMean: Float = 0.2877
        let sourceGamma = try makeToneSource(red: gammaX, green: gammaX, blue: gammaX)
        let sourceLinear = try makeToneSource(
            red: powf(gammaX, 2.2), green: powf(gammaX, 2.2), blue: powf(gammaX, 2.2)
        )
        let linearLumaMean = powf(gammaLumaMean, 2.2)

        let pOut = try runSingle(
            sourceGamma,
            filter: WhitesFilter(whites: 100, lumaMean: gammaLumaMean, colorSpace: .perceptual)
        )
        let lOut = try runSingle(
            sourceLinear,
            filter: WhitesFilter(whites: 100, lumaMean: linearLumaMean, colorSpace: .linear)
        )
        let yp = try readToneTexture(pOut)[4][4].r
        let yl = try readToneTexture(lOut)[4][4].r
        let ylAsGamma = powf(max(yl, 0), 1.0 / 2.2)

        XCTAssertEqual(
            ylAsGamma, yp, accuracy: 0.03,
            "Whites positive linear → re-gamma must match perceptual; got \(ylAsGamma) vs \(yp)"
        )
    }

    func testWhitesLinearNegativeMatchesPerceptualViaGammaWrap() throws {
        // Parity for negative branch too.
        let gammaX: Float = 0.7
        let sourceGamma = try makeToneSource(red: gammaX, green: gammaX, blue: gammaX)
        let sourceLinear = try makeToneSource(
            red: powf(gammaX, 2.2), green: powf(gammaX, 2.2), blue: powf(gammaX, 2.2)
        )

        let pOut = try runSingle(
            sourceGamma,
            filter: WhitesFilter(whites: -100, lumaMean: 0.5, colorSpace: .perceptual)
        )
        let lOut = try runSingle(
            sourceLinear,
            filter: WhitesFilter(whites: -100, lumaMean: powf(0.5, 2.2), colorSpace: .linear)
        )
        let yp = try readToneTexture(pOut)[4][4].r
        let yl = try readToneTexture(lOut)[4][4].r
        let ylAsGamma = powf(max(yl, 0), 1.0 / 2.2)

        XCTAssertEqual(
            ylAsGamma, yp, accuracy: 0.03,
            "Whites negative linear → re-gamma must match perceptual; got \(ylAsGamma) vs \(yp)"
        )
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
        // Perceptual-branch derivation. k=0.6312, a=2.1857.
        //   (0.9)^2.1857 ≈ 0.795
        //   y = 0.1·(1 + 0.6312·0.795) ≈ 0.150
        let source = try makeToneSource(red: 0.1, green: 0.1, blue: 0.1)
        let output = try runSingle(
            source, filter: BlacksFilter(blacks: 100, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.150, accuracy: 0.02)
    }

    func testBlacksPositiveFullSliderOnMidtone() throws {
        // Perceptual branch. (0.5)^2.1857 ≈ 0.220; y ≈ 0.569.
        let source = try makeToneSource(red: 0.5, green: 0.5, blue: 0.5)
        let output = try runSingle(
            source, filter: BlacksFilter(blacks: 100, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.569, accuracy: 0.02)
    }

    func testBlacksNegativeFullSliderCrushesShadow() throws {
        // Perceptual branch. k=-1.5515, a=2.3236. y ≈ 0.015.
        let source = try makeToneSource(red: 0.2, green: 0.2, blue: 0.2)
        let output = try runSingle(
            source, filter: BlacksFilter(blacks: -100, colorSpace: .perceptual)
        )
        let p = try readToneTexture(output)[4][4]
        XCTAssertEqual(p.r, 0.015, accuracy: 0.02)
    }

    func testBlacksMonotonicInSliderForShadow() throws {
        // For a fixed shadow input (0.15), sweeping slider -100 → +100 must
        // produce strictly monotonic output (crush → identity → lift).
        // Perceptual to preserve derived monotonic behaviour (linear wrap
        // preserves monotonicity too, but this test anchors perceptual).
        let source = try makeToneSource(red: 0.15, green: 0.15, blue: 0.15)
        var last: Float = -.infinity
        for slider: Float in [-100, -50, 0, 50, 100] {
            let output = try runSingle(
                source, filter: BlacksFilter(blacks: slider, colorSpace: .perceptual)
            )
            let p = try readToneTexture(output)[4][4]
            XCTAssertGreaterThan(
                p.r, last,
                "Blacks must be monotonic in slider; slider=\(slider) produced r=\(p.r) ≤ prev=\(last)"
            )
            last = p.r
        }
    }

    func testBlacksLinearModeMatchesPerceptualViaGammaWrap() throws {
        // Parity proof for Blacks linear wrap. See Contrast's parity test
        // for the methodology — same approach here.
        let gammaX: Float = 0.15
        let sourceGamma = try makeToneSource(red: gammaX, green: gammaX, blue: gammaX)
        let sourceLinear = try makeToneSource(
            red: powf(gammaX, 2.2), green: powf(gammaX, 2.2), blue: powf(gammaX, 2.2)
        )

        let perceptualOut = try runSingle(
            sourceGamma, filter: BlacksFilter(blacks: 100, colorSpace: .perceptual)
        )
        let linearOut = try runSingle(
            sourceLinear, filter: BlacksFilter(blacks: 100, colorSpace: .linear)
        )
        let yp = try readToneTexture(perceptualOut)[4][4].r
        let yl = try readToneTexture(linearOut)[4][4].r
        let ylAsGamma = powf(max(yl, 0), 1.0 / 2.2)

        XCTAssertEqual(
            ylAsGamma, yp, accuracy: 0.03,
            "Blacks linear → re-gamma must match perceptual output; got linear→gamma=\(ylAsGamma), perceptual=\(yp)"
        )
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
