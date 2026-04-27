//
//  SaturationVibranceOOGRobustnessTests.swift
//  DCRenderKitTests
//
//  Reproduction tests for the user-reported "Sat/Vib produces black
//  blobs even when not crashing" issue. The hypothesis being tested:
//  upstream HDR / out-of-gamut overshoot (e.g. WhiteBalance YIQ tint
//  matrix at extreme values, or a hand-constructed linear-sRGB texture
//  with sub-zero channels) flows into Saturation/Vibrance, whose OKLab
//  round-trip is undefined for negative linear sRGB and propagates the
//  negativity to the output. The final 8-bit clamp turns the negative
//  linear pixel into pure black — a "blob" wherever the upstream
//  overshoot fell.
//
//  Each test runs against a slightly out-of-gamut input and asserts
//  that the output is a sensible non-black colour.
//

import XCTest
@testable import DCRenderKit
import simd

final class SaturationVibranceOOGRobustnessTests: ContractTestCase {

    // MARK: - Slightly negative linear-sRGB input

    /// A pixel whose RED channel is slightly negative in linear-sRGB
    /// (a teal pixel where upstream Sharpen / Contrast / WhiteBalance
    /// overshoot pushed R below zero). The valid colour information
    /// is in the green and blue channels.
    ///
    /// `Saturation(s = 1.4)` should NOT produce a black pixel: the
    /// non-negative channels carry real colour. The fix should treat
    /// the negative R as 0 (no light) before the OKLab round-trip,
    /// yielding a saturated teal output.
    func testSaturationOnNegativeRedChannelDoesNotCollapseToBlack() throws {
        let oog = SIMD3<Float>(-0.1, 0.5, 0.5)
        let source = try makeSinglePatchTexture(oog)
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4)
        )
        let p = try readCentrePixel(output)

        // Non-black assertion: the green+blue energy of the input
        // (1.0 combined) cannot disappear. After clamping R to 0 the
        // input is teal (0, 0.5, 0.5); Saturation amplifies chroma but
        // never blackens. A robust output must preserve at least some
        // of the green / blue energy.
        XCTAssertGreaterThan(
            Double(p.y + p.z), 0.3,
            "Sat(1.4) on (-0.1, 0.5, 0.5) collapsed to black; OKLab math propagated upstream negative through gamut clamp instead of treating negative linear as 0. Got (\(p.x), \(p.y), \(p.z))."
        )
    }

    /// Same hypothesis, all three channels slightly negative. A gross
    /// upstream overshoot would land all-negative; the result should
    /// be black (no signal to recover) rather than NaN / undefined.
    /// This is the "graceful degradation" case.
    func testSaturationOnAllNegativeProducesNonNaNBlack() throws {
        let oog = SIMD3<Float>(-0.05, -0.05, -0.05)
        let source = try makeSinglePatchTexture(oog)
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4)
        )
        let p = try readCentrePixel(output)

        // All-negative input has no valid colour information. The
        // "right answer" is a defined low-luminance result — black is
        // acceptable. The contract is: no NaN / inf, all channels
        // finite.
        XCTAssertTrue(p.x.isFinite, "R must be finite, got \(p.x)")
        XCTAssertTrue(p.y.isFinite, "G must be finite, got \(p.y)")
        XCTAssertTrue(p.z.isFinite, "B must be finite, got \(p.z)")
        XCTAssertGreaterThanOrEqual(Double(p.x), -0.01, "R must not propagate strong negative")
        XCTAssertGreaterThanOrEqual(Double(p.y), -0.01, "G must not propagate strong negative")
        XCTAssertGreaterThanOrEqual(Double(p.z), -0.01, "B must not propagate strong negative")
    }

    // MARK: - Vibrance: same OOG hypothesis

    /// `Vibrance` shares the OKLab round-trip with `Saturation`; the
    /// same upstream-overshoot symptom should reproduce here.
    func testVibranceOnNegativeRedChannelDoesNotCollapseToBlack() throws {
        let oog = SIMD3<Float>(-0.1, 0.5, 0.5)
        let source = try makeSinglePatchTexture(oog)
        let output = try runFilter(
            source: source,
            filter: VibranceFilter(vibrance: 0.8)
        )
        let p = try readCentrePixel(output)

        XCTAssertGreaterThan(
            Double(p.y + p.z), 0.3,
            "Vibrance(0.8) on (-0.1, 0.5, 0.5) collapsed to black. Got (\(p.x), \(p.y), \(p.z))."
        )
    }

    // MARK: - HDR > 1 input (overshoot in the bright direction)

    /// Linear sRGB > 1 represents HDR — emitted by Exposure-positive,
    /// Sharpen, Clarity at high settings. OKLab math is well-defined
    /// for L > 1 (the gamut clamp will reduce C to 0 because no
    /// in-gamut chroma exists at L > 1) but the output luminance
    /// stays > 1, which the final 8-bit clamp pins at white — NOT
    /// black. This test guards against a regression where someone
    /// "fixes" the negative-input case by clamping inputs to [0, 1]
    /// (which would also kill HDR overshoot).
    func testSaturationOnHDRWhitishInputStaysBright() throws {
        let hdr = SIMD3<Float>(1.3, 1.3, 1.3)
        let source = try makeSinglePatchTexture(hdr)
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4)
        )
        let p = try readCentrePixel(output)

        // HDR grey in → HDR grey out (chroma stays ~0; saturation has
        // no chroma to amplify). Output should be ≥ 0.95 in all
        // channels (visibly bright), NOT black.
        XCTAssertGreaterThan(
            Double(p.x), 0.95,
            "Sat on HDR grey (1.3, 1.3, 1.3) lost luminance. Got R=\(p.x).")
        XCTAssertGreaterThan(Double(p.y), 0.95, "G=\(p.y)")
        XCTAssertGreaterThan(Double(p.z), 0.95, "B=\(p.z)")
    }

    // MARK: - Edge case probes (looking for the user's "dirty blob" trigger)

    /// Pure black input should stay black, never NaN.
    func testSaturationOnPureBlackStaysBlack() throws {
        let source = try makeSinglePatchTexture(SIMD3<Float>(0, 0, 0))
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4)
        )
        let p = try readCentrePixel(output)
        XCTAssertEqual(Double(p.x), 0, accuracy: 0.01)
        XCTAssertEqual(Double(p.y), 0, accuracy: 0.01)
        XCTAssertEqual(Double(p.z), 0, accuracy: 0.01)
    }

    /// Very dark colour at saturation=2 — chroma might amplify past
    /// the gamut, gamut clamp must keep output non-negative.
    func testSaturationOnVeryDarkColourDoesNotProduceNegative() throws {
        let source = try makeSinglePatchTexture(SIMD3<Float>(0.05, 0.01, 0.02))
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 2.0)
        )
        let p = try readCentrePixel(output)
        XCTAssertGreaterThanOrEqual(Double(p.x), -0.001, "R must not be negative; got \(p.x)")
        XCTAssertGreaterThanOrEqual(Double(p.y), -0.001, "G must not be negative; got \(p.y)")
        XCTAssertGreaterThanOrEqual(Double(p.z), -0.001, "B must not be negative; got \(p.z)")
    }

    /// HDR-overshoot pixel (a single channel > 1, others normal —
    /// e.g. a saturated red highlight). Sat=1.4 must amplify chroma
    /// without producing negative or NaN.
    func testSaturationOnHDRRedHighlightIsSane() throws {
        let source = try makeSinglePatchTexture(SIMD3<Float>(1.5, 0.2, 0.1))
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4)
        )
        let p = try readCentrePixel(output)
        XCTAssertGreaterThan(Double(p.x), Double(p.y),
                             "Red character lost: R=\(p.x), G=\(p.y)")
        XCTAssertGreaterThan(Double(p.x), Double(p.z),
                             "Red character lost: R=\(p.x), B=\(p.z)")
        XCTAssertGreaterThanOrEqual(Double(p.y), -0.001, "G negative: \(p.y)")
        XCTAssertGreaterThanOrEqual(Double(p.z), -0.001, "B negative: \(p.z)")
    }

    /// Two channels negative, one positive — the partial-overshoot
    /// pattern landing in a "weird" subspace. After defensive
    /// max(rgb, 0) input is (0, 0, 0.5) — pure blue.
    func testSaturationOnMixedNegativeProducesValidOutput() throws {
        let source = try makeSinglePatchTexture(SIMD3<Float>(-0.05, -0.05, 0.5))
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4)
        )
        let p = try readCentrePixel(output)
        XCTAssertGreaterThan(Double(p.z), 0.3,
                             "Blue character lost. Got (\(p.x), \(p.y), \(p.z))")
    }

    // MARK: - Perceptual-mode (the edit-preview "脏黑斑" trigger)

    /// In `.perceptual` mode the source texture carries sRGB-gamma
    /// values directly (raw `bgra8Unorm` from a JPEG / PNG loader).
    /// OKLab math is calibrated for **linear** sRGB; if the
    /// Saturation body fails to linearise the gamma input it produces
    /// a perceptually-wrong `L`, the gamut clamp converges to
    /// near-black on chromatic pixels, and the user sees scattered
    /// dark blobs in the edit preview.
    ///
    /// This test emulates the edit-preview path: a chromatic gamma-
    /// encoded mid-tone (gamma 0.6/0.3/0.5 ≈ linear 0.32/0.07/0.21
    /// — a muted purple) is fed into Saturation in perceptual mode at
    /// a non-trivial slider value. The output must be a sensible
    /// purple, NOT near-black.
    func testSaturationPerceptualModeOnGammaEncodedInputDoesNotBlacken() throws {
        let gammaInput = SIMD3<Float>(0.6, 0.3, 0.5)
        let source = try makeSinglePatchTexture(gammaInput)
        let output = try runFilter(
            source: source,
            filter: SaturationFilter(saturation: 1.4, colorSpace: .perceptual)
        )
        let p = try readCentrePixel(output)
        // The output gamma luminance should stay in the same
        // ball-park as the input. If the perceptual-mode round-trip
        // is broken, output collapses to near-black (all channels
        // < 0.05) on this kind of chromatic input.
        let outLuma = (Double(p.x) + Double(p.y) + Double(p.z)) / 3
        XCTAssertGreaterThan(
            outLuma, 0.2,
            "Perceptual-mode Saturation collapsed gamma input \(gammaInput) to near-black: got (\(p.x), \(p.y), \(p.z)). Body is failing to linearise input before OKLab math."
        )
    }

    func testVibrancePerceptualModeOnGammaEncodedInputDoesNotBlacken() throws {
        let gammaInput = SIMD3<Float>(0.6, 0.3, 0.5)
        let source = try makeSinglePatchTexture(gammaInput)
        let output = try runFilter(
            source: source,
            filter: VibranceFilter(vibrance: 0.8, colorSpace: .perceptual)
        )
        let p = try readCentrePixel(output)
        let outLuma = (Double(p.x) + Double(p.y) + Double(p.z)) / 3
        XCTAssertGreaterThan(
            outLuma, 0.2,
            "Perceptual-mode Vibrance collapsed gamma input \(gammaInput) to near-black: got (\(p.x), \(p.y), \(p.z))."
        )
    }

    /// `colorSpace = .linear` and `colorSpace = .perceptual` must
    /// both round-trip an identity-saturation input cleanly. Without
    /// the gamma-linear branch the perceptual path silently
    /// degrades.
    func testSaturationIdentityRoundtripInBothColorSpaces() throws {
        let probe = SIMD3<Float>(0.6, 0.3, 0.5)
        for space in [DCRColorSpace.linear, DCRColorSpace.perceptual] {
            let source = try makeSinglePatchTexture(probe)
            let output = try runFilter(
                source: source,
                filter: SaturationFilter(saturation: 1.0, colorSpace: space)
            )
            let p = try readCentrePixel(output)
            // Identity at saturation=1: output ≈ input on both spaces.
            // Tolerance covers Float16 round-trip.
            XCTAssertEqual(Double(p.x), Double(probe.x), accuracy: 0.01,
                           "\(space): R drift on identity")
            XCTAssertEqual(Double(p.y), Double(probe.y), accuracy: 0.01,
                           "\(space): G drift on identity")
            XCTAssertEqual(Double(p.z), Double(probe.z), accuracy: 0.01,
                           "\(space): B drift on identity")
        }
    }
}
