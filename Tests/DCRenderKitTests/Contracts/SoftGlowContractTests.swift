//
//  SoftGlowContractTests.swift
//  DCRenderKitTests
//
//  Verification of the SoftGlow filter against the 6 measurable
//  conditions in `docs/contracts/soft_glow.md` (§8.2 A+.3).
//
//  Slider conventions (per SoftGlowFilter.swift):
//    - strength:    0 ... 100    (internal × 0.35/100 compression)
//    - threshold:   0 ... 100    (remapped to 0.3 + (t/100)·0.6 in luma)
//    - bloomRadius: 0 ... 100    (remapped to 0.002 + (r/100)·0.004 share)
//
//  SoftGlowFilter conforms to `MultiPassFilter`; use `runMultiPassFilter`.
//

import XCTest
@testable import DCRenderKit
import simd

final class SoftGlowContractTests: ContractTestCase {

    // MARK: - C.1 Identity at strength = 0

    func testC1IdentityAtZeroStrength() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3<Float>(ZoneY.zoneV, ZoneY.zoneV, ZoneY.zoneV),
            SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII),
            ColorCheckerPatch.lightSkin,
            TestPatch.midGrey,
            SIMD3<Float>(0.9, 0.9, 0.9),
        ]
        for patch in patches {
            let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
            let output = try runMultiPassFilter(
                source: source,
                filter: SoftGlowFilter(strength: 0, threshold: 0, bloomRadius: 25)
            )
            let p = try readCentrePixel(output)
            XCTAssertEqual(p.x, patch.x, accuracy: 0.005, "C.1 R \(patch)")
            XCTAssertEqual(p.y, patch.y, accuracy: 0.005, "C.1 G \(patch)")
            XCTAssertEqual(p.z, patch.z, accuracy: 0.005, "C.1 B \(patch)")
        }
    }

    // MARK: - C.2 Threshold gate (below-threshold input produces no bloom)

    /// With threshold slider = 50 (internal luma threshold ≈ 0.6),
    /// a uniform input at Y = 0.3 is well below the smoothstep lower
    /// edge (0.5). The bright-downsample kernel gates it to zero, the
    /// pyramid accumulates zero, and Screen blend leaves input unchanged.
    func testC2ThresholdGate() throws {
        let patch = SIMD3<Float>(0.3, 0.3, 0.3)  // linear Y ≈ 0.3 (below threshold 0.6 − 0.1 = 0.5)
        let source = try makeSinglePatchTexture(patch, width: 64, height: 64)
        let output = try runMultiPassFilter(
            source: source,
            filter: SoftGlowFilter(strength: 100, threshold: 50, bloomRadius: 25)
        )
        let p = try readCentrePixel(output)
        XCTAssertEqual(p.x, patch.x, accuracy: 0.01, "C.2 R should not change (got \(p.x))")
        XCTAssertEqual(p.y, patch.y, accuracy: 0.01, "C.2 G should not change (got \(p.y))")
        XCTAssertEqual(p.z, patch.z, accuracy: 0.01, "C.2 B should not change (got \(p.z))")
    }

    // MARK: - C.3 Above-threshold contribution

    /// With threshold slider = 0 (internal luma threshold 0.3), a
    /// uniform Y=0.5 input is above threshold+0.1 (0.4), so the bright
    /// downsample passes full contribution. The pyramid blurs the now-
    /// uniform texture (no spatial structure), and Screen blend brightens
    /// the output.
    func testC3AboveThresholdContribution() throws {
        let patch = SIMD3<Float>(0.5, 0.5, 0.5)
        let source = try makeSinglePatchTexture(patch, width: 64, height: 64)
        let output = try runMultiPassFilter(
            source: source,
            filter: SoftGlowFilter(strength: 100, threshold: 0, bloomRadius: 25)
        )
        let p = try readCentrePixel(output)
        let inLuma: Float = 0.5
        let outLuma = simd_dot(SIMD3<Float>(p.x, p.y, p.z),
                               SIMD3<Float>(0.2126, 0.7152, 0.0722))
        XCTAssertGreaterThan(
            outLuma, inLuma + 0.01,
            "C.3 Y above threshold should brighten (in=\(inLuma), out=\(outLuma))"
        )
    }

    // MARK: - C.4 Spatial spread

    /// Centre-bright 4×4 spot (Y=0.9) in a 64×64 Y=0 image. After
    /// SoftGlow with strength=100, neighbouring pixels should see
    /// non-zero luma.
    ///
    /// The pyramid-depth formula `levels = max(3, floor(log2(shortSide/135)))`
    /// at shortSide=64 yields 3 levels (64 → 32 → 16 → 8). Tent upsamples
    /// over these levels give an effective blur radius of roughly the
    /// pyramid's coarsest level footprint, producing detectable bloom
    /// tens of pixels from the source spike even though the individual
    /// upsample offset is small.
    func testC4SpatialSpread() throws {
        let source = try makeCentreBrightSpot(
            size: 64, spotSize: 4, brightY: 0.9, backgroundY: 0.0
        )
        let output = try runMultiPassFilter(
            source: source,
            filter: SoftGlowFilter(strength: 100, threshold: 0, bloomRadius: 100)
        )
        let outLuma = lumaGrid(try readRGBGrid(output))

        // Centre (32,32) should have non-trivial output — at minimum it
        // still has the Screen-blend of its own bloom.
        let centreY = outLuma[32][32]
        XCTAssertGreaterThan(centreY, 0.5, "C.4 centre luma (got \(centreY))")

        // 8 px from centre along +x — inside the pyramid's close field.
        let near = outLuma[32][40]
        XCTAssertGreaterThan(
            near, 0.003,
            "C.4 luma at 8px from spot should be > 0.003 (got \(near))"
        )

        // 16 px out — at the outer edge of the middle pyramid level's
        // footprint. On a 64×64 image with 3 pyramid levels the effective
        // σ is roughly 8-10 px, so 16 px ≈ 1.6σ — expected density scales
        // as exp(-1.6²/2) / (2π σ²), ≈ 4·10⁻⁴ for the spot's energy
        // (observed ≈ 5·10⁻⁴). Threshold set at 3·10⁻⁴ to keep real
        // signal detectable while tolerating Float16 noise floor.
        let mid = outLuma[32][48]
        XCTAssertGreaterThan(
            mid, 0.0003,
            "C.4 luma at 16px from spot should be > 3e-4 (got \(mid))"
        )
    }

    // MARK: - C.5 Monotonicity in strength

    /// Fixed input above threshold; output luma non-decreasing in
    /// strength slider.
    func testC5StrengthMonotonicity() throws {
        let patch = SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII)
        let strengths: [Float] = [0, 30, 70, 100]
        var lumas: [Float] = []
        for s in strengths {
            let source = try makeSinglePatchTexture(patch, width: 64, height: 64)
            let out = try runMultiPassFilter(
                source: source,
                filter: SoftGlowFilter(strength: s, threshold: 0, bloomRadius: 25)
            )
            let p = try readCentrePixel(out)
            lumas.append(simd_dot(SIMD3<Float>(p.x, p.y, p.z),
                                  SIMD3<Float>(0.2126, 0.7152, 0.0722)))
        }
        for i in 1..<lumas.count {
            XCTAssertGreaterThanOrEqual(
                lumas[i], lumas[i - 1] - 0.003,
                "C.5 strength monotone: Y at s=\(strengths[i]) (\(lumas[i])) < s=\(strengths[i-1]) (\(lumas[i-1]))"
            )
        }
    }

    // MARK: - C.6 Gamut preservation

    func testC6GamutPreservation() throws {
        let patches: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(ZoneY.zoneV, ZoneY.zoneV, ZoneY.zoneV),
            SIMD3<Float>(ZoneY.zoneVII, ZoneY.zoneVII, ZoneY.zoneVII),
            SIMD3<Float>(1, 1, 1),
            ColorCheckerPatch.lightSkin,
            TestPatch.pureRed, TestPatch.pureGreen, TestPatch.pureBlue,
            TestPatch.pureCyan, TestPatch.pureMagenta, TestPatch.pureYellow,
        ]
        let combos: [(strength: Float, threshold: Float)] = [
            (0, 20), (0, 50), (0, 80),
            (50, 20), (50, 50), (50, 80),
            (100, 20), (100, 50), (100, 80),
        ]
        let margin: Float = 1.0 / 1024

        for patch in patches {
            for c in combos {
                let source = try makeSinglePatchTexture(patch, width: 32, height: 32)
                let out = try runMultiPassFilter(
                    source: source,
                    filter: SoftGlowFilter(
                        strength: c.strength, threshold: c.threshold, bloomRadius: 25
                    )
                )
                let p = try readCentrePixel(out)
                for (name, value) in [("R", p.x), ("G", p.y), ("B", p.z)] {
                    XCTAssertTrue(value.isFinite, "C.6 \(name) finite (\(patch) str=\(c.strength) thr=\(c.threshold))")
                    XCTAssertGreaterThanOrEqual(
                        value, -margin,
                        "C.6 \(name) < 0 (\(value)) (\(patch) str=\(c.strength) thr=\(c.threshold))"
                    )
                    XCTAssertLessThanOrEqual(
                        value, 1.0 + margin,
                        "C.6 \(name) > 1 (\(value)) (\(patch) str=\(c.strength) thr=\(c.threshold))"
                    )
                }
            }
        }
    }
}
