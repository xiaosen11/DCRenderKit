//
//  ExposureFilter.swift
//  DCRenderKit
//
//  Exposure adjustment filter. Ported from DigiCam's self-developed kernel.
//

import Foundation

/// Exposure adjustment — symmetric linear-gain operator with Reinhard
/// highlight roll-off on the positive branch.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Physical basis: `Exposure` is radiometrically just a linear
///   multiplication by `gain = exp2(ev)`. Doubling exposure = adding
///   one stop = one f-stop aperture change. Both branches start from
///   this primitive.
/// - **Positive direction**: Extended Reinhard tonemap around the
///   linear gain.
///   - Reference: Reinhard et al., *Photographic Tone Reproduction
///     for Digital Images*, SIGGRAPH 2002.
///     http://www.cs.utah.edu/~reinhard/cdrom/
///   - Without Reinhard, `x · gain` overshoots `1.0` for bright
///     input pixels at positive EV — visible as hard-clipped
///     highlights. The Reinhard map preserves highlight detail as
///     a soft roll-off toward the clip point.
///   - Whitepoint `w = 0.95 · gain` sets the "clip" anchor
///     just below the gain-scaled maximum, yielding a gentle
///     overshoot curve rather than an instant clip.
/// - **Negative direction**: pure linear gain `y = clamp(x · gain,
///   0, 1)`.
///   - Principled choice: at `ev < 0`, `gain < 1`, so `x · gain` is
///     strictly bounded by `gain ≤ 1`. There is no overshoot to
///     protect against, and inserting a tone-mapper on top of the
///     linear gain adds shaping that has no photographic
///     interpretation (Reinhard's whole purpose is overshoot
///     protection).
///   - Replaces the prior `A · x^γ + B · x` compound fit — that
///     form tried to model "consumer-app-reference darkening curve"
///     with a fitted polynomial + linear shoulder (MSE 2.82). Pure
///     linear gain is the physically exact "less light arrives at
///     the sensor" operation; any deviation from linear in the
///     darkening direction is a grading decision, not an exposure
///     one, and should live in Contrast / Blacks / WhiteBalance
///     rather than be bundled into the Exposure slider.
///
/// ## Parameter range
///
/// `exposure` is a slider value in `-100 ... +100`, compressed by
/// `0.7` so slider ±100 produces `±0.7 · EV_RANGE = ±2.975 EV`
/// (with `EV_RANGE = 4.25`). Identity at 0 via dead-zone.
///
/// ## Breaking change from pre-Session-C fitted negative curve
///
/// Negative-EV response shape changed from `A · x^γ + B · x` to
/// `x · gain`. Both agree at `ev = 0` (identity) and at `ev → −∞`
/// (both approach 0). Mid-ev behaviour drifts: the old compound
/// fit had a shoulder that lifted dark tones slightly; pure linear
/// gain darkens proportionally. This is intentional per Tier 2
/// "replace fitted curves with principled operators"
/// (findings-and-plan §8.5 B.1). If consumer presets relied on
/// the shadow-lift shoulder, that work belongs to ``BlacksFilter``
/// now — which itself is a Reinhard toe and addresses the same
/// shadow-lift intent with a grading-primitive.
@available(iOS 18.0, *)
public struct ExposureFilter: FilterProtocol {

    /// Exposure slider in stops-like units. Range `-100 ... +100`.
    /// Positive brightens with highlight rolloff; negative darkens with
    /// power-curve shoulder.
    public var exposure: Float

    /// Color space the input texture is encoded in. Drives the shader
    /// branch selection:
    ///   - ``DCRColorSpace/perceptual``: the shader applies an internal
    ///     `pow(,2.2)` linearize → Reinhard → `pow(,1/2.2)` de-linearize
    ///     (matches the product fit against the consumer-app reference's
    ///     gamma-space JPEG exports).
    ///   - ``DCRColorSpace/linear``: the input is already linear (either
    ///     the texture was loaded with `.SRGB: true` or upstream filters
    ///     produced linear values), so the shader skips the explicit
    ///     conversions and runs Reinhard on the values directly.
    ///
    /// Defaults to ``DCRenderKit/defaultColorSpace`` so the SDK's global
    /// color-space choice drives this filter without the consumer having
    /// to thread it through every construction site.
    public var colorSpace: DCRColorSpace

    /// Create an ``ExposureFilter`` with the given slider and
    /// pipeline's current color-space mode.
    public init(
        exposure: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.exposure = exposure
        self.colorSpace = colorSpace
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRExposureFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(ExposureUniforms(
            exposure: exposure / 100.0,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// Declared fuse group (`.toneAdjustment`). See
    /// ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { .toneAdjustment }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRExposureBody` lands in `ExposureFilter.metal` in Phase 3.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRExposureBody",
            uniformStructName: "ExposureUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceText: BundledShaderSources.exposureFilter,
            sourceLabel: "ExposureFilter.metal"
        )
    }
}

/// Memory layout matches `constant ExposureUniforms& u [[buffer(0)]]`
/// declared in `ExposureFilter.metal`.
struct ExposureUniforms {
    /// Slider value remapped to `-1.0 ... +1.0`. Shader applies its own
    /// clamp and ×0.7 product compression.
    var exposure: Float
    /// 1 = input is linear-light; 0 = input is perceptually-gamma-encoded.
    /// Written as UInt32 to match Metal `uint` layout alignment.
    var isLinearSpace: UInt32
}
