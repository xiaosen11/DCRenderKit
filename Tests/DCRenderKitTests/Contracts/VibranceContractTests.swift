//
//  VibranceContractTests.swift
//  DCRenderKitTests
//
//  Verification of the Vibrance filter against the 7 measurable
//  conditions in `docs/contracts/vibrance.md` (§8.2 A+.4).
//
//  Each test method here pairs one contract clause (C.1 through C.7).
//  Expected values are derived on the CPU via the `OKLab` Swift mirror
//  in `ContractTestHelpers.swift` so that a bug in the Metal shader
//  cannot silently validate itself.
//

import XCTest
@testable import DCRenderKit
import simd

final class VibranceContractTests: ContractTestCase {

    // MARK: - C.1 Identity at vibrance = 0

    /// Contract: `VibranceFilter(vibrance: 0)` must output the input
    /// verbatim within Float16 quantization (~0.2 %). Runs five
    /// representative patches (Macbeth skin pair + blue sky + mid-grey
    /// + pure primary).
    func testC1IdentityAtZero() throws {
        let patches: [SIMD3<Float>] = [
            ColorCheckerPatch.darkSkin,
            ColorCheckerPatch.lightSkin,
            ColorCheckerPatch.blueSky,
            TestPatch.midGrey,
            TestPatch.pureBlue,
        ]
        for patch in patches {
            let source = try makeSinglePatchTexture(patch)
            let output = try runFilter(source: source, filter: VibranceFilter(vibrance: 0))
            let p = try readCentrePixel(output)
            XCTAssertEqual(p.x, patch.x, accuracy: 0.005, "C.1: R should match for \(patch)")
            XCTAssertEqual(p.y, patch.y, accuracy: 0.005, "C.1: G should match for \(patch)")
            XCTAssertEqual(p.z, patch.z, accuracy: 0.005, "C.1: B should match for \(patch)")
        }
    }

    // MARK: - C.2 Monotonicity in vibrance

    /// Contract: for a fixed non-skin non-grey pixel, output OKLCh C
    /// is non-decreasing in vibrance over `[-1, +1]`. Uses a low-sat
    /// blue patch (well away from skin hue) so the protect weights are
    /// both ≈ 1 and the slider has a clear effect.
    func testC2MonotonicityInVibrance() throws {
        // Synthetic low-sat blue patch (L=0.6, C=0.04, h=250°).
        let input = try synthesizePatchFromOKLCh(L: 0.6, C: 0.04, hRadians: 250 * .pi / 180)
        let slider: [Float] = [-1.0, -0.5, 0, 0.5, 1.0]
        var chromas: [Float] = []
        for v in slider {
            let lch = try measureOutputOKLCh(input: input, filter: VibranceFilter(vibrance: v))
            chromas.append(lch.y)
        }
        for i in 1..<chromas.count {
            XCTAssertGreaterThanOrEqual(
                chromas[i], chromas[i - 1] - 0.002,
                "C.2: C at vib \(slider[i]) (\(chromas[i])) should be ≥ vib \(slider[i - 1]) (\(chromas[i - 1]))"
            )
        }
    }

    // MARK: - C.3 Low-vs-high-sat boost ratio ≥ 3:1

    /// Contract: at vibrance = +1, same non-skin hue, low-C input
    /// receives ≥ 3× the chroma boost a high-C input does.
    ///
    /// Constructing two synthetic patches at the same (L, h) with very
    /// different C is tricky in OKLCh — large C at non-primary hues
    /// readily escapes the sRGB gamut. Instead we use pure blue as the
    /// high-sat anchor (C ≈ 0.313, guaranteed in-gamut by construction)
    /// and synthesise a low-chroma patch at the same measured (L, h).
    /// Both share the same w_skin since they share a hue.
    ///
    /// ΔC is measured as `C_out − C_in`.
    func testC3LowVsHighSatBoostRatio() throws {
        let highIn = TestPatch.pureBlue
        let highInLCh = OKLab.linearSRGBToOKLCh(highIn)
        let lowIn = try synthesizePatchFromOKLCh(
            L: highInLCh.x, C: 0.05, hRadians: highInLCh.z
        )

        let lowBase = try measureInputOKLCh(lowIn)
        let highBase = try measureInputOKLCh(highIn)

        let filter = VibranceFilter(vibrance: 1.0)
        let lowOut = try measureOutputOKLCh(input: lowIn, filter: filter)
        let highOut = try measureOutputOKLCh(input: highIn, filter: filter)

        let lowDelta = lowOut.y - lowBase.y
        let highDelta = highOut.y - highBase.y

        XCTAssertGreaterThan(lowDelta, 0, "C.3: low-sat patch must gain chroma at vib=+1 (got \(lowDelta))")
        XCTAssertGreaterThanOrEqual(
            lowDelta, highDelta * 3.0,
            "C.3: low-sat boost (\(lowDelta)) should be ≥ 3× high-sat boost (\(highDelta))"
        )
    }

    // MARK: - C.4 Skin-hue protect ratio ≤ 0.5

    /// Contract: at vibrance = +1, Macbeth Light Skin patch receives
    /// at most half the chroma boost of an equivalent-(L, C) patch at
    /// a non-skin hue. The comparison patch reflects the skin hue 180°
    /// across the OKLCh hue axis to keep (L, C) identical.
    func testC4SkinProtectRatio() throws {
        let skinRGB = ColorCheckerPatch.lightSkin
        let skinLCh = OKLab.linearSRGBToOKLCh(skinRGB)

        // Mirror hue by +π (180°) to land on the opposite side of the
        // hue circle, well outside the skin gate.
        var mirroredHue = skinLCh.z + .pi
        if mirroredHue > .pi { mirroredHue -= 2 * .pi }
        let nonSkinRGB = try synthesizePatchFromOKLCh(
            L: skinLCh.x, C: skinLCh.y, hRadians: mirroredHue
        )

        let skinBase = try measureInputOKLCh(skinRGB)
        let nonSkinBase = try measureInputOKLCh(nonSkinRGB)

        let filter = VibranceFilter(vibrance: 1.0)
        let skinOut = try measureOutputOKLCh(input: skinRGB, filter: filter)
        let nonSkinOut = try measureOutputOKLCh(input: nonSkinRGB, filter: filter)

        let skinDelta = skinOut.y - skinBase.y
        let nonSkinDelta = nonSkinOut.y - nonSkinBase.y

        XCTAssertGreaterThan(
            nonSkinDelta, 0,
            "C.4: non-skin comparison patch must gain chroma (got \(nonSkinDelta))"
        )
        XCTAssertLessThanOrEqual(
            skinDelta, nonSkinDelta * 0.5,
            "C.4: skin boost (\(skinDelta)) should be ≤ 0.5 × non-skin boost (\(nonSkinDelta))"
        )
    }

    // MARK: - C.5 Gamut preservation

    /// Contract: for all vibrance ∈ [-1, +1] and all representative
    /// inputs, every output channel is finite and in `[0, 1]` (allowing
    /// the gamut margin 1/4096).
    func testC5GamutPreservation() throws {
        let patches: [SIMD3<Float>] = [
            ColorCheckerPatch.darkSkin,
            ColorCheckerPatch.lightSkin,
            ColorCheckerPatch.orange,
            ColorCheckerPatch.cyan,
            ColorCheckerPatch.macbethRed,
            ColorCheckerPatch.macbethGreen,
            ColorCheckerPatch.macbethBlue,
            TestPatch.midGrey,
            TestPatch.pureRed,
            TestPatch.pureGreen,
            TestPatch.pureBlue,
        ]
        let sliders: [Float] = [-1, -0.5, 0, 0.5, 1]
        let margin: Float = 1.0 / 1024.0  // bigger than shader's 1/4096 to cover Float16 quantization

        for patch in patches {
            for v in sliders {
                let source = try makeSinglePatchTexture(patch)
                let output = try runFilter(source: source, filter: VibranceFilter(vibrance: v))
                let p = try readCentrePixel(output)
                for (name, value) in [("R", p.x), ("G", p.y), ("B", p.z)] {
                    XCTAssertTrue(value.isFinite, "C.5: \(name) not finite (patch \(patch), vib \(v))")
                    XCTAssertGreaterThanOrEqual(
                        value, -margin,
                        "C.5: \(name) below gamut (\(value)) (patch \(patch), vib \(v))"
                    )
                    XCTAssertLessThanOrEqual(
                        value, 1.0 + margin,
                        "C.5: \(name) above gamut (\(value)) (patch \(patch), vib \(v))"
                    )
                }
            }
        }
    }

    // MARK: - C.6 L / h preservation (gamut clamp未触发区)

    /// Contract: in the clamp-safe region (low-to-mid chroma), output
    /// OKLab L and hue are within tight tolerance of the input. Uses
    /// synthesized low-chroma non-skin patches to guarantee no clamp.
    func testC6LAndHPreservation() throws {
        struct Patch { let L: Float; let C: Float; let hDeg: Float }
        let patches: [Patch] = [
            Patch(L: 0.4, C: 0.04, hDeg: 250),
            Patch(L: 0.6, C: 0.05, hDeg: 200),
            Patch(L: 0.7, C: 0.06, hDeg: 150),
        ]
        for patch in patches {
            let hRad = patch.hDeg * .pi / 180
            let input = try synthesizePatchFromOKLCh(L: patch.L, C: patch.C, hRadians: hRad)
            let baseLCh = try measureInputOKLCh(input)
            let outLCh = try measureOutputOKLCh(
                input: input, filter: VibranceFilter(vibrance: 1.0)
            )
            XCTAssertEqual(
                outLCh.x, baseLCh.x, accuracy: 0.005,
                "C.6: L should be preserved (patch L=\(patch.L) C=\(patch.C) h=\(patch.hDeg)°)"
            )
            // Angular diff in radians; 0.5° = 0.00873 rad.
            var dh = outLCh.z - baseLCh.z
            if dh >  .pi { dh -= 2 * .pi }
            if dh < -.pi { dh += 2 * .pi }
            XCTAssertLessThan(
                abs(dh), 0.02,
                "C.6: hue should be preserved — Δh = \(abs(dh) * 180 / .pi)° (patch L=\(patch.L) C=\(patch.C) h=\(patch.hDeg)°)"
            )
        }
    }

    // MARK: - C.7 Perceptually linear slider (soft)

    /// Soft contract: for a low-sat non-skin patch, ΔC at vibrance =
    /// 0.5 should be roughly half of ΔC at vibrance = 1.0. Marked soft
    /// because the smoothstep weights interact with the slider in a
    /// not-perfectly-linear way — we accept ±30% deviation.
    func testC7PerceptuallyLinearSliderSoft() throws {
        let input = try synthesizePatchFromOKLCh(L: 0.6, C: 0.05, hRadians: 250 * .pi / 180)
        let base = try measureInputOKLCh(input)
        let half = try measureOutputOKLCh(input: input, filter: VibranceFilter(vibrance: 0.5))
        let full = try measureOutputOKLCh(input: input, filter: VibranceFilter(vibrance: 1.0))

        let dHalf = half.y - base.y
        let dFull = full.y - base.y

        XCTAssertGreaterThan(dFull, 0, "C.7: vib=1 must boost chroma (got \(dFull))")
        let ratio = dHalf / dFull
        XCTAssertEqual(
            ratio, 0.5, accuracy: 0.15,
            "C.7 (soft): ΔC(0.5)/ΔC(1.0) = \(ratio) expected ≈ 0.5 ± 0.15"
        )
    }
}
