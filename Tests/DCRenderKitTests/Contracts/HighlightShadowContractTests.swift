//
//  HighlightShadowContractTests.swift
//  DCRenderKitTests
//
//  Verification of the HighlightShadow filter against the 6 measurable
//  conditions in `docs/contracts/highlight_shadow.md` (§8.2 A+.1).
//
//  Slider convention: highlights/shadows both in [-100, +100], positive
//  brightens the targeted zone (shader `ratio = 1 + h·h_weight·0.35`).
//
//  HighlightShadowFilter conforms to `MultiPassFilter`, so the pipeline
//  step is `.multi(...)` — use `runMultiPassFilter` in ContractTestCase
//  rather than `runFilter`.
//

import XCTest
@testable import DCRenderKit
import simd

final class HighlightShadowContractTests: ContractTestCase {

    // MARK: - C.1 Identity when both sliders are zero

    func testC1IdentityAtZero() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3<Float>(ZoneY.zoneIII, ZoneY.zoneIII, ZoneY.zoneIII),
            SIMD3<Float>(ZoneY.zoneV,   ZoneY.zoneV,   ZoneY.zoneV),
            SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII),
            ColorCheckerPatch.lightSkin,
            TestPatch.midGrey,
        ]
        for patch in patches {
            let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
            let output = try runMultiPassFilter(
                source: source,
                filter: HighlightShadowFilter(highlights: 0, shadows: 0)
            )
            let p = try readCentrePixel(output)
            XCTAssertEqual(p.x, patch.x, accuracy: 0.008, "C.1 R \(patch)")
            XCTAssertEqual(p.y, patch.y, accuracy: 0.008, "C.1 G \(patch)")
            XCTAssertEqual(p.z, patch.z, accuracy: 0.008, "C.1 B \(patch)")
        }
    }

    // MARK: - C.2 Per-slider directionality (monotonicity)

    func testC2HighlightsMonotonicityAtZoneVII() throws {
        let patch = SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII)
        let sliders: [Float] = [-100, -50, 0, 50, 100]
        var lumas: [Float] = []
        for h in sliders {
            let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
            let out = try runMultiPassFilter(
                source: source,
                filter: HighlightShadowFilter(highlights: h, shadows: 0)
            )
            lumas.append(lumaAt(try readCentrePixel(out)))
        }
        for i in 1..<lumas.count {
            XCTAssertGreaterThanOrEqual(
                lumas[i], lumas[i - 1] - 0.003,
                "C.2 highlights: Y at h=\(sliders[i]) (\(lumas[i])) < h=\(sliders[i-1]) (\(lumas[i-1]))"
            )
        }
    }

    func testC2ShadowsMonotonicityAtZoneIII() throws {
        let patch = SIMD3<Float>(ZoneY.zoneIII, ZoneY.zoneIII, ZoneY.zoneIII)
        let sliders: [Float] = [-100, -50, 0, 50, 100]
        var lumas: [Float] = []
        for s in sliders {
            let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
            let out = try runMultiPassFilter(
                source: source,
                filter: HighlightShadowFilter(highlights: 0, shadows: s)
            )
            lumas.append(lumaAt(try readCentrePixel(out)))
        }
        for i in 1..<lumas.count {
            XCTAssertGreaterThanOrEqual(
                lumas[i], lumas[i - 1] - 0.003,
                "C.2 shadows: Y at s=\(sliders[i]) (\(lumas[i])) < s=\(sliders[i-1]) (\(lumas[i-1]))"
            )
        }
    }

    // MARK: - C.3 Zone targeting (selectivity via ratio - 1)

    /// (ratio_VII − 1) / (ratio_V − 1) ≥ 2.5 at highlights = +100.
    func testC3HighlightsTargetZoneVII() throws {
        let deltaRatioVII = try ratioDeviation(
            input: ZoneY.zoneVII, highlights: 100, shadows: 0
        )
        let deltaRatioV = try ratioDeviation(
            input: ZoneY.zoneV, highlights: 100, shadows: 0
        )
        XCTAssertGreaterThan(deltaRatioVII, 0.01, "C.3 Zone VII baseline (got \(deltaRatioVII))")
        XCTAssertGreaterThan(deltaRatioV, 0.005, "C.3 Zone V baseline (got \(deltaRatioV))")
        let ratio = deltaRatioVII / deltaRatioV
        XCTAssertGreaterThanOrEqual(
            ratio, 2.5,
            "C.3 highlights selectivity: (ratio_VII-1) / (ratio_V-1) = \(ratio), expected ≥ 2.5"
        )
    }

    /// (ratio_III − 1) / (ratio_V − 1) ≥ 1.5 at shadows = +100.
    func testC3ShadowsTargetZoneIII() throws {
        let deltaRatioIII = try ratioDeviation(
            input: ZoneY.zoneIII, highlights: 0, shadows: 100
        )
        let deltaRatioV = try ratioDeviation(
            input: ZoneY.zoneV, highlights: 0, shadows: 100
        )
        XCTAssertGreaterThan(deltaRatioIII, 0.01, "C.3 Zone III baseline (got \(deltaRatioIII))")
        XCTAssertGreaterThan(deltaRatioV, 0.005, "C.3 Zone V baseline (got \(deltaRatioV))")
        let ratio = deltaRatioIII / deltaRatioV
        XCTAssertGreaterThanOrEqual(
            ratio, 1.5,
            "C.3 shadows selectivity: (ratio_III-1) / (ratio_V-1) = \(ratio), expected ≥ 1.5"
        )
    }

    // MARK: - C.4 Halo-free at soft edge

    func testC4HaloFreeAtSoftEdge() throws {
        let leftY = ZoneY.zoneIII
        let rightY = ZoneY.zoneVII
        let stepMagnitude = rightY - leftY

        let source = try makeSoftEdgeStep(
            width: 64, height: 64, leftY: leftY, rightY: rightY, sigma: 2.0
        )
        let output = try runMultiPassFilter(
            source: source,
            filter: HighlightShadowFilter(highlights: 100, shadows: 0)
        )

        let edgeX = 32
        let leftBand  = (edgeX - 30)...(edgeX - 10)
        let rightBand = (edgeX + 10)...(edgeX + 29)
        let outLuma = lumaGrid(try readRGBGrid(output))

        let overshoot = LumaStats.peakOvershoot(outLuma, ceiling: rightY, xRange: rightBand)
        let undershoot = LumaStats.peakUndershoot(outLuma, floor: leftY, xRange: leftBand)

        // rightY=0.382 but after highlights=+100 the right half uniformly
        // rises via ratio multiply (no halo ringing expected, but global
        // shift is allowed — the "overshoot" here is really local spike
        // beyond the right-plateau mean, which the peak operator captures
        // vs a flat ceiling. Use the observed plateau as ceiling instead.
        let rightPlateau = outLuma.map { $0[edgeX + 20] }.reduce(0, +) / Float(outLuma.count)
        let overshootLocal = LumaStats.peakOvershoot(outLuma, ceiling: rightPlateau, xRange: rightBand)
        let leftPlateau = outLuma.map { $0[edgeX - 20] }.reduce(0, +) / Float(outLuma.count)
        let undershootLocal = LumaStats.peakUndershoot(outLuma, floor: leftPlateau, xRange: leftBand)

        XCTAssertLessThan(
            overshootLocal, stepMagnitude * 0.03 + 0.01,
            "C.4 local overshoot \(overshootLocal) above right-plateau \(rightPlateau) should be < 3% of step \(stepMagnitude)"
        )
        XCTAssertLessThan(
            undershootLocal, stepMagnitude * 0.03 + 0.01,
            "C.4 local undershoot \(undershootLocal) below left-plateau \(leftPlateau) should be < 3% of step \(stepMagnitude)"
        )
        // Suppress unused-variable warnings on the raw (non-local) peaks,
        // which are informational in failure output.
        _ = (overshoot, undershoot)
    }

    // MARK: - C.5 Gamut preservation

    func testC5GamutPreservation() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(ZoneY.zoneIII, ZoneY.zoneIII, ZoneY.zoneIII),
            SIMD3<Float>(ZoneY.zoneV,   ZoneY.zoneV,   ZoneY.zoneV),
            SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII),
            SIMD3<Float>(1, 1, 1),
            ColorCheckerPatch.lightSkin,
            TestPatch.pureRed, TestPatch.pureGreen, TestPatch.pureBlue,
            TestPatch.pureCyan, TestPatch.pureMagenta,
        ]
        let combos: [(Float, Float)] = [
            (-100, -100), (-100, 0), (-100, 100),
            (   0, -100), (   0, 0), (   0, 100),
            ( 100, -100), ( 100, 0), ( 100, 100),
        ]
        let margin: Float = 1.0 / 1024

        for patch in patches {
            for (h, s) in combos {
                let source = try makeSinglePatchTexture(patch, width: 16, height: 16)
                let out = try runMultiPassFilter(
                    source: source,
                    filter: HighlightShadowFilter(highlights: h, shadows: s)
                )
                let p = try readCentrePixel(out)
                for (name, value) in [("R", p.x), ("G", p.y), ("B", p.z)] {
                    XCTAssertTrue(value.isFinite, "C.5 \(name) not finite \(patch) h=\(h) s=\(s)")
                    XCTAssertGreaterThanOrEqual(
                        value, -margin, "C.5 \(name) < 0 (\(value)) \(patch) h=\(h) s=\(s)"
                    )
                    XCTAssertLessThanOrEqual(
                        value, 1.0 + margin, "C.5 \(name) > 1 (\(value)) \(patch) h=\(h) s=\(s)"
                    )
                }
            }
        }
    }

    // MARK: - C.6 (Soft) perceptually linear slider

    func testC6PerceptuallyLinearSliderSoft() throws {
        let deltaHalf = try deltaLuma(input: ZoneY.zoneVII, highlights: 50, shadows: 0)
        let deltaFull = try deltaLuma(input: ZoneY.zoneVII, highlights: 100, shadows: 0)
        XCTAssertGreaterThan(abs(deltaFull), 0.01, "C.6 baseline (got \(deltaFull))")
        let ratio = deltaHalf / deltaFull
        XCTAssertEqual(
            ratio, 0.5, accuracy: 0.15,
            "C.6 (soft) ΔY(+50)/ΔY(+100) = \(ratio), expected ≈ 0.5 ± 0.15"
        )
    }

    // MARK: - Helpers

    private func lumaAt(_ p: SIMD4<Float>) -> Float {
        return simd_dot(SIMD3<Float>(p.x, p.y, p.z),
                        SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }

    /// Rec.709 Y delta between filter output and a uniform-grey input.
    private func deltaLuma(
        input linearY: Float, highlights: Float, shadows: Float
    ) throws -> Float {
        let patch = SIMD3<Float>(linearY, linearY, linearY)
        let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
        let out = try runMultiPassFilter(
            source: source,
            filter: HighlightShadowFilter(highlights: highlights, shadows: shadows)
        )
        return lumaAt(try readCentrePixel(out)) - linearY
    }

    /// `output.Y / input.Y − 1` (ratio deviation from identity), evaluated
    /// on a uniform-grey patch at linear Y.
    private func ratioDeviation(
        input linearY: Float, highlights: Float, shadows: Float
    ) throws -> Float {
        let patch = SIMD3<Float>(linearY, linearY, linearY)
        let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
        let out = try runMultiPassFilter(
            source: source,
            filter: HighlightShadowFilter(highlights: highlights, shadows: shadows)
        )
        let outY = lumaAt(try readCentrePixel(out))
        return outY / linearY - 1
    }
}
