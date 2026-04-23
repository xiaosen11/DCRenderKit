//
//  ClarityContractTests.swift
//  DCRenderKitTests
//
//  Verification of the Clarity filter against the 7 measurable
//  conditions in `docs/contracts/clarity.md` (§8.2 A+.2).
//
//  Slider convention: intensity in [-100, +100], positive amplifies
//  mid-frequency detail via guided-filter residual (×1.5 product
//  compression), negative blends toward the smooth base (×0.7).
//
//  ClarityFilter conforms to `MultiPassFilter`; use `runMultiPassFilter`.
//

import XCTest
@testable import DCRenderKit
import simd

final class ClarityContractTests: ContractTestCase {

    // MARK: - C.1 Identity at intensity = 0

    func testC1IdentityAtZero() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3<Float>(ZoneY.zoneV, ZoneY.zoneV, ZoneY.zoneV),
            SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII),
            ColorCheckerPatch.lightSkin,
            TestPatch.midGrey,
            TestPatch.pureRed,
        ]
        for patch in patches {
            let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
            let output = try runMultiPassFilter(
                source: source,
                filter: ClarityFilter(intensity: 0)
            )
            let p = try readCentrePixel(output)
            XCTAssertEqual(p.x, patch.x, accuracy: 0.005, "C.1 R \(patch)")
            XCTAssertEqual(p.y, patch.y, accuracy: 0.005, "C.1 G \(patch)")
            XCTAssertEqual(p.z, patch.z, accuracy: 0.005, "C.1 B \(patch)")
        }
    }

    // MARK: - C.2 Local-variance monotonicity (positive intensity)

    /// 8-px checker texture: intensity sweep {0, +50, +100} must
    /// produce non-decreasing luma variance (more positive Clarity →
    /// more local contrast).
    func testC2LocalVarianceMonotonicity() throws {
        let intensities: [Float] = [0, 50, 100]
        var variances: [Float] = []
        for i in intensities {
            let source = try makeCheckerTexture(
                width: 64, height: 64, blockPx: 8, darkY: 0.25, brightY: 0.55
            )
            let output = try runMultiPassFilter(
                source: source, filter: ClarityFilter(intensity: i)
            )
            let luma = lumaGrid(try readRGBGrid(output))
            variances.append(LumaStats.variance(luma))
        }
        for k in 1..<variances.count {
            XCTAssertGreaterThanOrEqual(
                variances[k], variances[k - 1] - 0.0005,
                "C.2 variance at i=\(intensities[k]) (\(variances[k])) < i=\(intensities[k-1]) (\(variances[k-1]))"
            )
        }
    }

    // MARK: - C.3 Low-frequency preservation

    /// Horizontal ramp (large-scale gradient only, no mid-freq texture).
    /// Clarity +100 should leave this nearly unchanged because the
    /// guided filter captures the entire gradient into the base; detail
    /// ≈ 0; no amplification to apply.
    func testC3LowFreqPreservation() throws {
        let source = try makeHorizontalRamp(
            width: 64, height: 64, yLeft: 0.1, yRight: 0.9
        )
        let inLuma = lumaGrid(try readRGBGrid(source))
        let output = try runMultiPassFilter(
            source: source, filter: ClarityFilter(intensity: 100)
        )
        let outLuma = lumaGrid(try readRGBGrid(output))

        // Mean absolute deviation — averaged per-pixel |out - in|.
        var sumAbs: Float = 0
        var count: Float = 0
        for y in 0..<inLuma.count {
            for x in 0..<inLuma[y].count {
                sumAbs += abs(outLuma[y][x] - inLuma[y][x])
                count += 1
            }
        }
        let meanAbs = count > 0 ? sumAbs / count : 0
        XCTAssertLessThan(
            meanAbs, 0.03,
            "C.3 mean|out-in| on smooth ramp should be < 0.03 (got \(meanAbs))"
        )
    }

    // MARK: - C.4 Mid-frequency amplification

    /// Checker at 8-px blocks (luma 0.25 vs 0.55). Clarity +100 must
    /// increase the observed luma amplitude (max − min).
    func testC4MidFreqAmplification() throws {
        let source = try makeCheckerTexture(
            width: 64, height: 64, blockPx: 8, darkY: 0.25, brightY: 0.55
        )
        let inLuma = lumaGrid(try readRGBGrid(source))
        let inAmplitude = LumaStats.amplitude(inLuma)

        let output = try runMultiPassFilter(
            source: source, filter: ClarityFilter(intensity: 100)
        )
        let outLuma = lumaGrid(try readRGBGrid(output))
        let outAmplitude = LumaStats.amplitude(outLuma)

        XCTAssertGreaterThan(
            outAmplitude, inAmplitude * 1.2,
            "C.4 amplitude should grow by ≥ 20 % (in=\(inAmplitude), out=\(outAmplitude))"
        )
    }

    // MARK: - C.5 Edge preservation (no ringing)

    /// Sharp Zone III ↔ Zone VII step, intensity = +100. Peak local
    /// over/undershoot (beyond the steady plateau, in a band 10-30 px
    /// from the edge) must stay < 5 % of step magnitude.
    func testC5EdgePreservation() throws {
        let leftY = ZoneY.zoneIII
        let rightY = ZoneY.zoneVII
        let stepMagnitude = rightY - leftY

        let source = try makeSharpStep(
            width: 64, height: 64, leftY: leftY, rightY: rightY
        )
        let output = try runMultiPassFilter(
            source: source, filter: ClarityFilter(intensity: 100)
        )
        let outLuma = lumaGrid(try readRGBGrid(output))

        let edgeX = 32
        let leftBand = (edgeX - 30)...(edgeX - 10)
        let rightBand = (edgeX + 10)...(edgeX + 29)

        // Use mid-band sample as plateau reference so any global gain is
        // subtracted — this test is specifically about halos relative to
        // the steady-state value, not absolute Y shift.
        let rightPlateau = outLuma.map { $0[edgeX + 20] }.reduce(0, +) / Float(outLuma.count)
        let leftPlateau = outLuma.map { $0[edgeX - 20] }.reduce(0, +) / Float(outLuma.count)
        let overshoot = LumaStats.peakOvershoot(outLuma, ceiling: rightPlateau, xRange: rightBand)
        let undershoot = LumaStats.peakUndershoot(outLuma, floor: leftPlateau, xRange: leftBand)

        XCTAssertLessThan(
            overshoot, stepMagnitude * 0.05 + 0.01,
            "C.5 overshoot \(overshoot) above right-plateau \(rightPlateau), step=\(stepMagnitude)"
        )
        XCTAssertLessThan(
            undershoot, stepMagnitude * 0.05 + 0.01,
            "C.5 undershoot \(undershoot) below left-plateau \(leftPlateau), step=\(stepMagnitude)"
        )
    }

    // MARK: - C.6 Dynamic range preservation

    /// Output amplitude shouldn't explode beyond input amplitude × 1.5.
    /// Per-patch check on the checker texture from C.4 — the ×1.5
    /// positive-intensity product compression bounds the growth.
    func testC6DynamicRangePreservation() throws {
        let source = try makeCheckerTexture(
            width: 64, height: 64, blockPx: 8, darkY: 0.25, brightY: 0.55
        )
        let inAmplitude = LumaStats.amplitude(lumaGrid(try readRGBGrid(source)))

        for intensity in [Float(-100), -50, 0, 50, 100] {
            let output = try runMultiPassFilter(
                source: source, filter: ClarityFilter(intensity: intensity)
            )
            let outAmplitude = LumaStats.amplitude(lumaGrid(try readRGBGrid(output)))
            XCTAssertLessThanOrEqual(
                outAmplitude, inAmplitude * 1.5 + 0.05,
                "C.6 at intensity=\(intensity): out amplitude \(outAmplitude) should be ≤ \(inAmplitude * 1.5 + 0.05)"
            )
        }
    }

    // MARK: - C.7 Gamut preservation

    func testC7GamutPreservation() throws {
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
        let intensities: [Float] = [-100, -50, 0, 50, 100]
        let margin: Float = 1.0 / 1024

        for patch in patches {
            for i in intensities {
                let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
                let out = try runMultiPassFilter(
                    source: source, filter: ClarityFilter(intensity: i)
                )
                let p = try readCentrePixel(out)
                for (name, value) in [("R", p.x), ("G", p.y), ("B", p.z)] {
                    XCTAssertTrue(value.isFinite, "C.7 \(name) not finite \(patch) i=\(i)")
                    XCTAssertGreaterThanOrEqual(
                        value, -margin, "C.7 \(name) < 0 (\(value)) \(patch) i=\(i)"
                    )
                    XCTAssertLessThanOrEqual(
                        value, 1.0 + margin, "C.7 \(name) > 1 (\(value)) \(patch) i=\(i)"
                    )
                }
            }
        }
    }
}
