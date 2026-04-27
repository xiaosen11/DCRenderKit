//
//  SDKFilterOutputContractTests.swift
//  DCRenderKitTests
//
//  SDK-wide contract test: every shipped filter, given an in-gamut
//  input pixel and any legal slider position, must produce output
//  whose channels are ≥ 0 (HDR overshoot above 1 is allowed).
//
//  Why: downstream consumers (notably the OKLab-based Saturation /
//  Vibrance filters) are mathematically defined only for non-negative
//  linear sRGB. A producer leaking negative channels — even slightly,
//  even at "extreme but legal" slider positions — propagates as a
//  black-blob artifact ("脏黑点") through any OKLab-using consumer
//  in the same chain. The same contract also matches `bgra8Unorm`
//  output semantics: an 8-bit display-encoded surface cannot
//  represent negative light.
//
//  Each filter gets one or more synthetic in-gamut probes (skin
//  patch, pure primary, neutral grey) and is run at extreme legal
//  parameters. The output channels must be ≥ -ε across every probe.
//

import XCTest
@testable import DCRenderKit
import simd

final class SDKFilterOutputContractTests: ContractTestCase {

    /// Tolerance for "non-negative" — a tiny float-precision /
    /// half-precision underflow is acceptable; a perceptible negative
    /// is not.
    private let nonNegativeTolerance: Double = -0.005

    private func assertOutputNonNegative(
        _ p: SIMD4<Float>,
        filter: String,
        input: SIMD3<Float>,
        params: String
    ) {
        XCTAssertGreaterThanOrEqual(
            Double(p.x), nonNegativeTolerance,
            "\(filter)(\(params)) on input \(input) leaked R=\(p.x); the SDK contract requires every filter to produce non-negative linear-sRGB output."
        )
        XCTAssertGreaterThanOrEqual(
            Double(p.y), nonNegativeTolerance,
            "\(filter)(\(params)) on input \(input) leaked G=\(p.y)."
        )
        XCTAssertGreaterThanOrEqual(
            Double(p.z), nonNegativeTolerance,
            "\(filter)(\(params)) on input \(input) leaked B=\(p.z)."
        )
    }

    private let probes: [SIMD3<Float>] = [
        SIMD3<Float>(0.5, 0.5, 0.5),                  // neutral grey
        ColorCheckerPatch.lightSkin,                   // skin
        SIMD3<Float>(1.0, 0.0, 0.0),                  // pure red primary
        SIMD3<Float>(0.0, 0.0, 1.0),                  // pure blue primary
        SIMD3<Float>(0.05, 0.95, 0.05),               // saturated green near-edge
    ]

    // MARK: - WhiteBalance: the historical leaker

    /// WhiteBalance YIQ tint matrix can drive output channels
    /// slightly negative at extreme tint values. Verified at
    /// `tint = ±200` against several in-gamut probes.
    func testWhiteBalancePerceptualModeAtExtremeTintIsNonNegative() throws {
        let cases: [(temp: Float, tint: Float)] = [
            (5500, +200),  // extreme green tint
            (5500, -200),  // extreme magenta tint
            (4000, +200),  // cool + extreme green
            (8000, -200),  // warm + extreme magenta
        ]
        for probe in probes {
            for c in cases {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source,
                    filter: WhiteBalanceFilter(
                        temperature: c.temp,
                        tint: c.tint,
                        colorSpace: .perceptual
                    )
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "WhiteBalance(perceptual)",
                    input: probe,
                    params: "temp=\(c.temp), tint=\(c.tint)"
                )
            }
        }
    }

    func testWhiteBalanceLinearModeAtExtremeTintIsNonNegative() throws {
        let cases: [(temp: Float, tint: Float)] = [
            (5500, +200), (5500, -200), (4000, +200), (8000, -200)
        ]
        for probe in probes {
            for c in cases {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source,
                    filter: WhiteBalanceFilter(
                        temperature: c.temp,
                        tint: c.tint,
                        colorSpace: .linear
                    )
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "WhiteBalance(linear)",
                    input: probe,
                    params: "temp=\(c.temp), tint=\(c.tint)"
                )
            }
        }
    }

    // MARK: - Tone operators

    func testExposureAtExtremesIsNonNegative() throws {
        for probe in probes {
            for ev in [Float(-100), Float(+100)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source,
                    filter: ExposureFilter(exposure: ev)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Exposure", input: probe, params: "ev=\(ev)"
                )
            }
        }
    }

    func testContrastAtExtremesIsNonNegative() throws {
        for probe in probes {
            for v in [Float(-100), Float(+100)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source,
                    filter: ContrastFilter(contrast: v, lumaMean: 0.5)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Contrast", input: probe, params: "c=\(v)"
                )
            }
        }
    }

    func testWhitesAtExtremesIsNonNegative() throws {
        for probe in probes {
            for v in [Float(-100), Float(+100)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source, filter: WhitesFilter(whites: v)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Whites", input: probe, params: "w=\(v)"
                )
            }
        }
    }

    func testBlacksAtExtremesIsNonNegative() throws {
        for probe in probes {
            for v in [Float(-100), Float(+100)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source, filter: BlacksFilter(blacks: v)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Blacks", input: probe, params: "b=\(v)"
                )
            }
        }
    }

    // MARK: - Colour grading (OKLab-based)

    func testSaturationAtExtremesIsNonNegative() throws {
        for probe in probes {
            for v in [Float(0), Float(2)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source, filter: SaturationFilter(saturation: v)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Saturation", input: probe, params: "s=\(v)"
                )
            }
        }
    }

    func testVibranceAtExtremesIsNonNegative() throws {
        for probe in probes {
            for v in [Float(-1), Float(+1)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source, filter: VibranceFilter(vibrance: v)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Vibrance", input: probe, params: "v=\(v)"
                )
            }
        }
    }

    // MARK: - Effects

    func testSharpenAtExtremesIsNonNegative() throws {
        for probe in probes {
            for v in [Float(0), Float(100)] {
                let source = try makeSinglePatchTexture(probe)
                let output = try runFilter(
                    source: source, filter: SharpenFilter(amount: v, stepPixels: 1)
                )
                let p = try readCentrePixel(output)
                assertOutputNonNegative(
                    p, filter: "Sharpen", input: probe, params: "amt=\(v)"
                )
            }
        }
    }

    func testFilmGrainAtExtremesIsNonNegative() throws {
        for probe in probes {
            let source = try makeSinglePatchTexture(probe)
            let output = try runFilter(
                source: source,
                filter: FilmGrainFilter(
                    density: 1.0, roughness: 1.0, chromaticity: 1.0, grainSizePixels: 1.0
                )
            )
            let p = try readCentrePixel(output)
            assertOutputNonNegative(
                p, filter: "FilmGrain", input: probe, params: "max"
            )
        }
    }

    func testFilmGrainAPIIsCorrect() {
        _ = FilmGrainFilter(density: 1.0, roughness: 1.0, chromaticity: 1.0, grainSizePixels: 1.0)
    }

    func testCCDAtExtremesIsNonNegative() throws {
        for probe in probes {
            let source = try makeSinglePatchTexture(probe)
            let output = try runFilter(
                source: source,
                filter: CCDFilter(
                    strength: 100, digitalNoise: 100, chromaticAberration: 100,
                    sharpening: 100, saturationBoost: 100
                )
            )
            let p = try readCentrePixel(output)
            assertOutputNonNegative(
                p, filter: "CCD", input: probe, params: "max"
            )
        }
    }

}
