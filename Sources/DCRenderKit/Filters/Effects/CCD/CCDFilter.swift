//
//  CCDFilter.swift
//  DCRenderKit
//
//  Compound CCD sensor simulation: chromatic aberration + saturation
//  boost + digital noise + sharpening, all fused into a single compute
//  kernel. Ported from DigiCam.
//

import Foundation

/// Early-era CCD camera **aesthetic** — not a sensor-physical simulation.
/// Fuses chromatic aberration, saturation boost, digital noise, and
/// sharpening into one compute kernel to produce a vintage-CCD look.
///
/// The step order (CA → saturation → noise → sharpen) is an artistic
/// narrative ("lens aberration → color tint → sensor grain → post
/// polish"), not the real ISP pipeline — see
/// `Shaders/Effects/CCD/CCDFilter.metal` for the comparison against
/// `github.com/cruxopen/openISP`. Fusing the four effects eliminates
/// three intermediate texture passes vs. running them as separate
/// `FilterProtocol` stages.
///
/// ## Composition order (inside the kernel)
///
/// 1. **Chromatic aberration** — horizontal R/B offset of up to
///    `caMaxOffsetPixels`. Spatial-param: `5.0pt × pixelsPerPoint`.
/// 2. **Saturation boost** — Rec.709 luma-anchored saturation.
///    Saturation slider `0 ... 100` remaps to a multiplier in
///    `1.0 ... 1.3` (half the magnitude of a standalone saturation).
/// 3. **Digital noise** — same sin-trick + block-quantized + symmetric-
///    SoftLight pipeline as `FilmGrainFilter`, with `roughness = density`
///    and `chromaticity` fixed at `0.6` (CCD noise is slightly chromatic).
///    Spatial-param: `grainSizePixels = 1.5pt × pixelsPerPoint`.
/// 4. **Sharpening** — Luma-channel Laplacian unsharp mask sampled from
///    the original source (so noise is not re-sharpened, and CA color
///    fringes are not re-hardened into visible edges). Spatial-param:
///    `sharpStepPixels = round(0.5pt × pixelsPerPoint)`. Compressed to
///    60% of `SharpenFilter` amplitude to balance against the other
///    three.
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
/// All three spatial params (`grainSizePixels`, `sharpStepPixels`,
/// `caMaxOffsetPixels`) are **pixel values**; consumers inject the
/// `pt × pixelsPerPoint` product so the effect looks pt-identical
/// across capture / editing / export. Defaults correspond to a 3×
/// Retina capture preview.
@available(iOS 18.0, *)
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

    /// Grain block size in **pixels of the current texture**.
    ///
    /// **Pixel value, not pt value.** Per `.claude/rules/spatial-
    /// params.md` §1, pass `1.5pt × pixelsPerPoint`. Filter does not
    /// know the display context.
    public var grainSizePixels: Float

    /// Sharpen sampling step in **pixels of the current texture**.
    ///
    /// **Pixel value, not pt value.** Per `.claude/rules/spatial-
    /// params.md` §1, pass `round(0.5pt × pixelsPerPoint)`.
    public var sharpStepPixels: Float

    /// Max chromatic-aberration offset in **pixels of the current
    /// texture**.
    ///
    /// **Pixel value, not pt value.** Per `.claude/rules/spatial-
    /// params.md` §1, pass `5.0pt × pixelsPerPoint`.
    public var caMaxOffsetPixels: Float

    /// Create a ``CCDFilter`` with the five aesthetic sliders and
    /// three `pixelsPerPoint`-scaled spatial defaults. See the
    /// per-property doc for each `*Pixels` field's `basePt ×
    /// pixelsPerPoint` formula.
    public init(
        strength: Float = 100,
        digitalNoise: Float = 50,
        chromaticAberration: Float = 50,
        sharpening: Float = 50,
        saturationBoost: Float = 50,
        grainSizePixels: Float = 4.5,
        sharpStepPixels: Float = 1.5,
        caMaxOffsetPixels: Float = 15.0
    ) {
        self.strength = strength
        self.digitalNoise = digitalNoise
        self.chromaticAberration = chromaticAberration
        self.sharpening = sharpening
        self.saturationBoost = saturationBoost
        self.grainSizePixels = grainSizePixels
        self.sharpStepPixels = sharpStepPixels
        self.caMaxOffsetPixels = caMaxOffsetPixels
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRCCDFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(CCDUniforms(
            strength: strength / 100.0,
            density: digitalNoise / 100.0,
            caAmount: chromaticAberration / 100.0,
            sharpAmount: sharpening / 100.0,
            grainSize: grainSizePixels,
            // FIXME(§8.6 Tier 2): × 0.3 saturation-boost compression
            // (slider 100 → saturation multiplier 1.3) is inherited
            // empirical, claimed above as "half the magnitude of a
            // standalone saturation" (~1.6). Rationale is qualitative.
            // Origin of the 50%-of-standalone choice lost with fitting
            // pipeline. Validation: findings-and-plan.md §8.6 Tier 2.
            saturation: 1.0 + (saturationBoost / 100.0) * 0.3,
            sharpStep: sharpStepPixels,
            caMaxOffset: caMaxOffsetPixels
        ))
    }


    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRCCDBody` lands in `CCDFilter.metal` in Phase 3.
    ///
    /// `radius = 32` is the neighbour-sample upper bound: the CCD
    /// shader reads horizontally-offset R/B channels for CA
    /// (`caMaxOffsetPixels`), samples a block-centre pixel for grain
    /// luma (up to `grainSizePixels`), and reads ± `sharpStepPixels`
    /// for the luma sharpening stage. All three defaults
    /// (`caMaxOffsetPixels = 15`, `grainSizePixels = 4.5`,
    /// `sharpStepPixels = 1.5`) are in pixels at 3× screen and scale
    /// with `pixelsPerPoint`; 32 covers the heaviest-zoom preview
    /// context with margin.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRCCDBody",
            uniformStructName: "CCDUniforms",
            kind: .neighborRead(radius: 32),
            wantsLinearInput: false,
            sourceText: BundledShaderSources.ccdFilter,
            sourceLabel: "CCDFilter.metal",
            signatureShape: .neighborReadWithSource
        )
    }
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
