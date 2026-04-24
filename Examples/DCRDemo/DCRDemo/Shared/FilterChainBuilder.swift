//
//  FilterChainBuilder.swift
//  DCRDemo
//
//  Translates `EditParameters` into a DCRenderKit filter chain. Pure
//  function — no state, no side effects — so camera and edit paths
//  can share the same mapping logic.
//

import Foundation
import Metal
import DCRenderKit

@MainActor
enum FilterChainBuilder {

    /// Build an ordered chain of filters from the current parameters.
    ///
    /// Order matches DigiCam's `EditParameters.toHarbethFilters()` so
    /// downstream visual comparison between DigiCam and DCRDemo stays
    /// apples-to-apples: tone → colour grade → clarity → sharpen →
    /// grain / CCD / soft glow / portrait blur → LUT.
    ///
    /// - Parameters:
    ///   - params: Current slider state.
    ///   - lumaMean: Pre-computed mean luminance of the source, in
    ///     `[0, 1]`. Drives `ContrastFilter`'s scene-adaptive pivot.
    ///     Pass `0.5` as a neutral default when the value isn't known
    ///     (e.g. first camera frame before the first reduction
    ///     completes). Note: `WhitesFilter` no longer consumes this
    ///     value (Session C dropped the `lumaMean:` argument; the
    ///     Filmic shoulder doesn't need a scene-adaptive pivot).
    ///   - pixelsPerPoint: Display-context multiplier for visual-texture
    ///     parameters. Capture preview = `UIScreen.main.scale` (3 on
    ///     modern iPhones); editing preview = `imageWidth / viewWidthPt`.
    ///   - portraitMask: Optional `MTLTexture` (R8Unorm) for
    ///     `PortraitBlurFilter`. Pass `nil` for camera preview unless
    ///     you've run Vision and cached the mask.
    static func build(
        from params: EditParameters,
        lumaMean: Float = 0.5,
        pixelsPerPoint: Float = 3.0,
        portraitMask: MTLTexture? = nil
    ) -> [AnyFilter] {
        var chain: [AnyFilter] = []

        // 1. Exposure
        if params.exposure != 0 {
            chain.append(.single(ExposureFilter(exposure: params.exposure)))
        }

        // 2. Contrast (luma-mean adaptive)
        if params.contrast != 0 {
            chain.append(.single(ContrastFilter(
                contrast: params.contrast,
                lumaMean: lumaMean
            )))
        }

        // 3. Highlights + Shadows (combined as one MultiPass filter)
        if params.highlights != 0 || params.shadows != 0 {
            chain.append(.multi(HighlightShadowFilter(
                highlights: params.highlights,
                shadows: params.shadows
            )))
        }

        // 4. Whites — Filmic-shoulder operator. Session C dropped the
        // `lumaMean:` argument (the shoulder concentrates effect at
        // x → 1 by construction; no scene-adaptive pivot needed).
        if params.whites != 0 {
            chain.append(.single(WhitesFilter(whites: params.whites)))
        }

        // 5. Blacks
        if params.blacks != 0 {
            chain.append(.single(BlacksFilter(blacks: params.blacks)))
        }

        // 6. White balance (Kelvin + tint). DigiCam's non-linear Kelvin mapping:
        //    slider >= 0 → 5000 + slider/100 · 1800  (+100 → 6800 K)
        //    slider  < 0 → 5000 + slider/100 ·  600  (-100 → 4400 K)
        //    tint:       slider/100 · 120
        if params.temperature != 0 || params.tint != 0 {
            let kelvin: Float
            if params.temperature >= 0 {
                kelvin = 5000 + params.temperature / 100.0 * 1800.0
            } else {
                kelvin = 5000 + params.temperature / 100.0 * 600.0
            }
            let tintValue = params.tint / 100.0 * 120.0
            chain.append(.single(WhiteBalanceFilter(
                temperature: kelvin,
                tint: tintValue
            )))
        }

        // 7. Vibrance
        if params.vibrance != 0 {
            // DigiCam: vibrance/100 · 0.72 (40% product compression)
            chain.append(.single(VibranceFilter(
                vibrance: params.vibrance / 100.0 * 0.72
            )))
        }

        // 8. Saturation
        if params.saturation != 0 {
            // DigiCam: 1 + slider/100 · 0.6 (40% product compression)
            chain.append(.single(SaturationFilter(
                saturation: 1.0 + params.saturation / 100.0 * 0.6
            )))
        }

        // 9. Clarity
        if params.clarity != 0 {
            chain.append(.multi(ClarityFilter(intensity: params.clarity)))
        }

        // 10. Sharpen (pt-aware step)
        if params.sharpening > 0 {
            chain.append(.single(SharpenFilter(
                amount: params.sharpening,
                step: max(round(1.0 * pixelsPerPoint), 1)
            )))
        }

        // 11. Film grain (density = filmGrain; chromaticity = filmGrainColor)
        if params.filmGrain > 0 {
            chain.append(.single(FilmGrainFilter(
                density: params.filmGrain / 100.0,
                roughness: params.filmGrain / 100.0,   // share with density for UI simplicity
                chromaticity: params.filmGrainColor / 100.0,
                grainSize: max(1.5 * pixelsPerPoint, 1)
            )))
        }

        // 12. CCD
        if params.ccdStrength > 0 {
            chain.append(.single(CCDFilter(
                strength: params.ccdStrength,
                digitalNoise: params.ccdDigitalNoise,
                chromaticAberration: params.ccdChromaticAberration,
                sharpening: params.ccdSharpening,
                saturationBoost: params.ccdSaturation,
                grainSize: max(1.5 * pixelsPerPoint, 1),
                sharpStep: max(round(0.5 * pixelsPerPoint), 1),
                caMaxOffset: 5.0 * pixelsPerPoint
            )))
        }

        // 13. Soft glow
        if params.softGlowStrength > 0 {
            chain.append(.multi(SoftGlowFilter(
                strength: params.softGlowStrength,
                threshold: params.softGlowThreshold,
                bloomRadius: params.softGlowBloomRadius
            )))
        }

        // 14. Portrait blur (needs a mask — skip in camera preview
        //     unless the caller has pre-computed one via Vision).
        //     Session C upgraded `PortraitBlurFilter` from
        //     `FilterProtocol` to `MultiPassFilter` (two-pass Poisson
        //     with 90°-rotated pattern); call site uses `.multi(...)`.
        if params.portraitBlurStrength > 0, let mask = portraitMask {
            chain.append(.multi(PortraitBlurFilter(
                strength: params.portraitBlurStrength,
                maskTexture: mask
            )))
        }

        // 15. LUT
        if params.lutPreset != .none,
           let lut = LUTRegistry.shared.filter(
               for: params.lutPreset,
               intensity: params.lutIntensity / 100.0
           ) {
            chain.append(.single(lut))
        }

        return chain
    }
}
