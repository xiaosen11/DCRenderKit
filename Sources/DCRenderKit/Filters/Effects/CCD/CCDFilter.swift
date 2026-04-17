//
//  CCDFilter.swift
//  DCRenderKit
//
//  Compound CCD sensor simulation: chromatic aberration + saturation
//  boost + digital noise + sharpening, all fused into a single compute
//  kernel. Ported from DigiCam.
//

import Foundation

/// Early-era CCD sensor emulation as a single compute kernel with four
/// subordinate effects. Fusing the four subordinate effects eliminates
/// three intermediate texture passes vs. running them as separate
/// `FilterProtocol` stages.
///
/// ## Composition order (inside the kernel)
///
/// 1. **Chromatic aberration** — horizontal R/B offset of up to
///    `caMaxOffset` pixels. Spatial-param: `5.0pt × pixelsPerPoint`.
/// 2. **Saturation boost** — Rec.709 luma-anchored saturation.
///    Saturation slider `0 ... 100` remaps to a multiplier in
///    `1.0 ... 1.3` (half the magnitude of a standalone saturation).
/// 3. **Digital noise** — same sin-trick + block-quantized + symmetric-
///    SoftLight pipeline as `FilmGrainFilter`, with `roughness = density`
///    and `chromaticity` fixed at `0.6` (CCD noise is slightly chromatic).
///    Spatial-param: `grainSize = 1.5pt × pixelsPerPoint`.
/// 4. **Sharpening** — Luma-channel Laplacian unsharp mask sampled from
///    the original source (so noise is not re-sharpened, and CA color
///    fringes are not re-hardened into visible edges). Spatial-param:
///    `sharpStep = 0.5pt × pixelsPerPoint`. Compressed to 60% of
///    `SharpenFilter` amplitude to balance against the other three.
///
/// ## Why one fused kernel?
///
/// The four effects share the source texture and only the final
/// composite output is ever observed. Running them as four stages would
/// allocate three intermediate `rgba16Float` textures and read/write
/// them three times. The fused kernel reads the source a few extra
/// times (for sharpening neighbors and noise-block centers) but never
/// materializes an intermediate, which is a net win for every viable
/// texture size.
///
/// ## Spatial parameters (rules/spatial-params.md §1)
///
/// All three spatial params (`grainSize`, `sharpStep`, `caMaxOffset`)
/// are visual-texture parameters; consumers inject the pt×pixelsPerPoint
/// product so the effect looks pt-identical across capture / editing /
/// export. Defaults correspond to a 3× Retina capture preview.
public struct CCDFilter: FilterProtocol {

    /// Overall effect strength, `0 ... 100`. Maps to a linear mix between
    /// the pristine source and the processed color at the tail of the kernel.
    public var strength: Float

    /// Digital-noise intensity `0 ... 100`. Drives both noise density
    /// and noise roughness (they share the slider for UI simplicity).
    public var digitalNoise: Float

    /// Chromatic-aberration intensity `0 ... 100`. Scales the horizontal
    /// R/B offset.
    public var chromaticAberration: Float

    /// Sharpening intensity `0 ... 100`.
    public var sharpening: Float

    /// Saturation boost `0 ... 100`. Remaps to saturation multiplier
    /// `1.0 ... 1.3` (half the magnitude of a standalone saturation).
    public var saturationBoost: Float

    /// Grain block size in pixels. Pass `1.5pt × pixelsPerPoint`.
    public var grainSize: Float

    /// Sharpen sampling step in pixels. Pass `0.5pt × pixelsPerPoint`.
    public var sharpStep: Float

    /// Max chromatic-aberration offset in pixels. Pass `5.0pt × pixelsPerPoint`.
    public var caMaxOffset: Float

    public init(
        strength: Float = 100,
        digitalNoise: Float = 50,
        chromaticAberration: Float = 50,
        sharpening: Float = 50,
        saturationBoost: Float = 50,
        grainSize: Float = 4.5,
        sharpStep: Float = 1.5,
        caMaxOffset: Float = 15.0
    ) {
        self.strength = strength
        self.digitalNoise = digitalNoise
        self.chromaticAberration = chromaticAberration
        self.sharpening = sharpening
        self.saturationBoost = saturationBoost
        self.grainSize = grainSize
        self.sharpStep = sharpStep
        self.caMaxOffset = caMaxOffset
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRCCDFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(CCDUniforms(
            strength: strength / 100.0,
            density: digitalNoise / 100.0,
            caAmount: chromaticAberration / 100.0,
            sharpAmount: sharpening / 100.0,
            grainSize: grainSize,
            saturation: 1.0 + (saturationBoost / 100.0) * 0.3,
            sharpStep: sharpStep,
            caMaxOffset: caMaxOffset
        ))
    }

    public static var fuseGroup: FuseGroup? { nil }
}

/// Memory layout matches `constant CCDUniforms& u [[buffer(0)]]`.
struct CCDUniforms {
    var strength: Float
    var density: Float
    var caAmount: Float
    var sharpAmount: Float
    var grainSize: Float
    var saturation: Float   // 1.0 ... 1.3
    var sharpStep: Float
    var caMaxOffset: Float
}
