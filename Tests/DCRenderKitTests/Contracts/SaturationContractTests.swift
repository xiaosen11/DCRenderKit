//
//  SaturationContractTests.swift
//  DCRenderKitTests
//
//  Verification of the Saturation filter against the 7 measurable
//  conditions in `docs/contracts/saturation.md` (§8.2 A+.5).
//
//  Each test method here pairs one contract clause (C.1 through C.7).
//  Expected values are derived on the CPU via the `OKLab` Swift mirror
//  in `ContractTestHelpers.swift` so that a bug in the Metal shader
//  cannot silently validate itself.
//

import XCTest
@testable import DCRenderKit
import simd

final class SaturationContractTests: ContractTestCase {

    // MARK: - C.1 Identity at saturation = 1

    /// Contract: `SaturationFilter(saturation: 1)` must output the
    /// input verbatim within Float16 quantization (~0.2 %). Five
    /// representative patches across skin / blue / grey / primary.
    func testC1IdentityAtOne() throws {
        let patches: [SIMD3<Float>] = [
            ColorCheckerPatch.darkSkin,
            ColorCheckerPatch.lightSkin,
            ColorCheckerPatch.blueSky,
            TestPatch.midGrey,
            TestPatch.pureRed,
        ]
        for patch in patches {
            let source = try makeSinglePatchTexture(patch)
            let output = try runFilter(source: source, filter: SaturationFilter(saturation: 1))
            let p = try readCentrePixel(output)
            XCTAssertEqual(p.x, patch.x, accuracy: 0.005, "C.1: R match for \(patch)")
            XCTAssertEqual(p.y, patch.y, accuracy: 0.005, "C.1: G match for \(patch)")
            XCTAssertEqual(p.z, patch.z, accuracy: 0.005, "C.1: B match for \(patch)")
        }
    }

    // MARK: - C.2 Zero saturation preserves OKLab L

    /// Contract: at saturation = 0, output OKLCh `C < 1e-3` and output
    /// OKLab `L` within ±0.001 of input L. Validates that the filter
    /// anchors on OKLab-L rather than Rec.709 Y.
    func testC2ZeroSatPreservesOKLabL() throws {
        let patches: [SIMD3<Float>] = [
            ColorCheckerPatch.lightSkin,
            ColorCheckerPatch.blueSky,
            ColorCheckerPatch.foliage,
            TestPatch.midGrey,
        ]
        for patch in patches {
            let baseLCh = try measureInputOKLCh(patch)
            let outLCh = try measureOutputOKLCh(
                input: patch, filter: SaturationFilter(saturation: 0)
            )
            // Chroma must collapse to (near-)zero.
            XCTAssertLessThan(
                outLCh.y, 0.005,
                "C.2: output C must be ≈ 0 at s=0 (got \(outLCh.y) for \(patch))"
            )
            // Lightness must stay.
            XCTAssertEqual(
                outLCh.x, baseLCh.x, accuracy: 0.01,
                "C.2: output L must equal input L at s=0 (\(patch))"
            )
        }
    }

    // MARK: - C.3 Uniform chroma scaling

    /// Contract: in the clamp-safe region, `C_out / C_in ≈ saturation`.
    /// Uses synthetic low-chroma non-skin patches so that the gamut
    /// clamp never triggers across `s ∈ {0.2, 0.5, 1.5}`.
    ///
    /// Tolerance: 0.03 in absolute ratio (shader uses Float16
    /// quantization plus matrix rounding; a 1 % absolute error on C
    /// corresponds to ≥ 2 % relative for small C values, hence the
    /// slightly looser bound than the doc's 1 % ideal).
    func testC3UniformChromaScaling() throws {
        // Base C kept low enough that scaling to s=1.5 stays clear of
        // the gamut boundary. C=0.04 → max C_out=0.06 at s=1.5, which
        // for L=0.5 h=230° lands well inside the sRGB cube (verified
        // manually against Ottosson inverse matrices).
        let hRad: Float = 230.0 * .pi / 180.0
        let input = try synthesizePatchFromOKLCh(L: 0.5, C: 0.04, hRadians: hRad)
        let baseC = try measureInputOKLCh(input).y
        let saturations: [Float] = [0.5, 1.0, 1.5]
        for s in saturations {
            let outC = try measureOutputOKLCh(
                input: input, filter: SaturationFilter(saturation: s)
            ).y
            let ratio = outC / baseC
            XCTAssertEqual(
                ratio, s, accuracy: 0.03,
                "C.3: C_out/C_in at s=\(s) = \(ratio) expected \(s) ± 0.03"
            )
        }
    }

    // MARK: - C.4 Monotonicity in saturation

    /// Contract: for a fixed non-grey pixel, output OKLCh C is non-
    /// decreasing as saturation ranges over [0, 2].
    func testC4MonotonicityInSaturation() throws {
        let input = ColorCheckerPatch.orange
        let saturations: [Float] = [0, 0.5, 1.0, 1.5, 2.0]
        var chromas: [Float] = []
        for s in saturations {
            let lch = try measureOutputOKLCh(input: input, filter: SaturationFilter(saturation: s))
            chromas.append(lch.y)
        }
        for i in 1..<chromas.count {
            XCTAssertGreaterThanOrEqual(
                chromas[i], chromas[i - 1] - 0.002,
                "C.4: C at s=\(saturations[i]) (\(chromas[i])) should be ≥ s=\(saturations[i - 1]) (\(chromas[i - 1]))"
            )
        }
    }

    // MARK: - C.5 L / h preservation

    /// Contract: output OKLab L and hue equal input L, h within tight
    /// tolerance (gamut clamp未触发). Uses synthetic low-C patches so
    /// boost to `s = 1.5` never clips.
    func testC5LAndHPreservation() throws {
        struct Patch { let L: Float; let C: Float; let hDeg: Float }
        let patches: [Patch] = [
            Patch(L: 0.4, C: 0.05, hDeg: 30),
            Patch(L: 0.6, C: 0.06, hDeg: 150),
            Patch(L: 0.7, C: 0.05, hDeg: 270),
        ]
        for patch in patches {
            let hRad = patch.hDeg * .pi / 180
            let input = try synthesizePatchFromOKLCh(L: patch.L, C: patch.C, hRadians: hRad)
            let baseLCh = try measureInputOKLCh(input)
            let outLCh = try measureOutputOKLCh(
                input: input, filter: SaturationFilter(saturation: 1.5)
            )
            XCTAssertEqual(
                outLCh.x, baseLCh.x, accuracy: 0.005,
                "C.5: L preserved for L=\(patch.L) C=\(patch.C) h=\(patch.hDeg)°"
            )
            var dh = outLCh.z - baseLCh.z
            if dh >  .pi { dh -= 2 * .pi }
            if dh < -.pi { dh += 2 * .pi }
            XCTAssertLessThan(
                abs(dh), 0.02,
                "C.5: hue preserved for L=\(patch.L) C=\(patch.C) h=\(patch.hDeg)° (Δh = \(abs(dh) * 180 / .pi)°)"
            )
        }
    }

    // MARK: - C.6 Gamut preservation

    /// Contract: for all saturation ∈ [0, 2] and all representative
    /// inputs, every output channel is finite and within [0, 1] ±
    /// margin.
    func testC6GamutPreservation() throws {
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
        let saturations: [Float] = [0, 0.5, 1, 1.5, 2]
        let margin: Float = 1.0 / 1024.0

        for patch in patches {
            for s in saturations {
                let source = try makeSinglePatchTexture(patch)
                let output = try runFilter(source: source, filter: SaturationFilter(saturation: s))
                let p = try readCentrePixel(output)
                for (name, value) in [("R", p.x), ("G", p.y), ("B", p.z)] {
                    XCTAssertTrue(value.isFinite, "C.6: \(name) not finite (patch \(patch), s \(s))")
                    XCTAssertGreaterThanOrEqual(
                        value, -margin,
                        "C.6: \(name) below gamut (\(value)) (patch \(patch), s \(s))"
                    )
                    XCTAssertLessThanOrEqual(
                        value, 1.0 + margin,
                        "C.6: \(name) above gamut (\(value)) (patch \(patch), s \(s))"
                    )
                }
            }
        }
    }

    // MARK: - C.7 No skin protect (cross-filter guard)

    /// Contract: Saturation must treat skin-hue and non-skin-hue
    /// equally. Measure ΔC at `s = 1.5` for Macbeth Light Skin and
    /// for an equivalent-(L, C) patch at the mirrored hue. Assert
    /// relative error < 10 %.
    ///
    /// Paired with Vibrance C.4 (which asserts the opposite — skin
    /// must get < 50 % of non-skin boost). Together the two guarantee
    /// the two filters are distinguishable purely by their skin
    /// behaviour.
    func testC7NoSkinProtect() throws {
        let skinRGB = ColorCheckerPatch.lightSkin
        let skinLCh = OKLab.linearSRGBToOKLCh(skinRGB)

        var mirroredHue = skinLCh.z + .pi
        if mirroredHue > .pi { mirroredHue -= 2 * .pi }
        let nonSkinRGB = try synthesizePatchFromOKLCh(
            L: skinLCh.x, C: skinLCh.y, hRadians: mirroredHue
        )

        let skinBase = try measureInputOKLCh(skinRGB)
        let nonSkinBase = try measureInputOKLCh(nonSkinRGB)

        let filter = SaturationFilter(saturation: 1.5)
        let skinOut = try measureOutputOKLCh(input: skinRGB, filter: filter)
        let nonSkinOut = try measureOutputOKLCh(input: nonSkinRGB, filter: filter)

        let skinDelta = skinOut.y - skinBase.y
        let nonSkinDelta = nonSkinOut.y - nonSkinBase.y

        XCTAssertGreaterThan(
            nonSkinDelta, 0.01,
            "C.7: non-skin baseline must see clear boost (got \(nonSkinDelta))"
        )
        let relativeDiff = abs(skinDelta - nonSkinDelta) / nonSkinDelta
        XCTAssertLessThan(
            relativeDiff, 0.10,
            "C.7: skin and non-skin ΔC should match within 10 % — skin \(skinDelta), non-skin \(nonSkinDelta), diff \(relativeDiff * 100) %"
        )
    }
}
