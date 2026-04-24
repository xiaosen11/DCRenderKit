//
//  ContrastFilter.swift
//  DCRenderKit
//
//  Contrast adjustment with luma-mean adaptive S-curve. Ported from DigiCam.
//

import Foundation

/// Contrast adjustment via log-space slope around a scene-adaptive
/// luminance pivot (DaVinci Resolve primary-contrast formulation).
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Algorithm: **log-space slope** `y = pivot · (x / pivot)^slope`
///   where `slope = exp2(contrast · 1.585)`.
///   - Per-channel, applied in gamma (display) space and clamped to
///     `[0, 1]`.
///   - Raising linear `log x` around a pivot by a multiplicative slope
///     is the **standard primary-contrast operator** used by DaVinci
///     Resolve (see the curve-math write-up at
///     https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
///     §"slope/offset/power", and ACES RRT's S-curve middle linear
///     segment definition which uses the same form).
///   - `slope = exp2(contrast · 1.585)` so `slider = ±1` yields
///     `slope ∈ {1/3, 3}` — the commercial grading convention "3× or
///     1/3× contrast at slider extremes" (±1.585 stops of log-space
///     amplification).
///   - `pivot` is the image's **mean luminance** (scene-adaptive).
///     Dark scenes end up with a lower pivot (crushing shadows,
///     lifting highlights); bright scenes end up with a higher
///     pivot (crushing highlights, lifting shadows). This matches the
///     photographer's intuition that "contrast" should pivot around
///     the scene's own midpoint rather than a fixed gray (DaVinci by
///     default fixes pivot at 0.18 for scene-invariant grading; we
///     optimise for UI feel rather than grading-room invariance).
/// - Why **not** the prior cubic pivot
///   (`y = x + k·x·(1-x)·(x-pivot)`): the cubic was a fitted polynomial
///   against gamma-space consumer-photo-app exports (MSE 52.1), with
///   no closed-form principle behind the specific coefficient shape.
///   Log-space slope is the principled version of the same intent —
///   no fit, a single well-known photo-grading primitive.
///
/// ## Parameter range
///
/// - `contrast`: slider in `-100 ... +100`, normalised to `-1 ... +1`
///   and raised to the log-space slope exponent via
///   `slope = exp2(±1.585)`.
/// - `lumaMean`: pre-computed mean-luminance pivot of the source,
///   expected in `(0, 1)`. Consumers typically obtain it via a single
///   reduction pass (`ImageStatistics.lumaMean`). The shader clamps it
///   to `[0.05, 0.95]` for numerical stability — a pivot at 0 or 1
///   degenerates the `pow` expression.
///
/// Identity at `contrast = 0` (slope = 1, curve degenerates to y = x).
///
/// ## Breaking change from pre-Session-C fitted cubic
///
/// Switching from fitted cubic to log-space slope changes the response
/// shape across all slider positions. The curves agree at `contrast =
/// 0` (both pass through y = x) and at the tonal endpoints, but the
/// midtone region behaves more like a DaVinci slope control and less
/// like the prior cubic. Existing presets that depended on the cubic's
/// exact midtone curvature need retuning; this is intentional per the
/// Session C "replace fitted tone curves with principled operators"
/// decision.
public struct ContrastFilter: FilterProtocol {

    /// Contrast slider. Range `-100 ... +100`.
    public var contrast: Float

    /// Image mean luma, `[0, 1]`, in the pipeline's current color space.
    /// In `.perceptual` mode pass the gamma-space mean; in `.linear` mode
    /// pass the linear-space mean — the shader converts to the gamma-space
    /// anchor domain that the k / pivot fit was done in. Shader clamps to
    /// `[0.05, 0.95]` for numerical stability.
    public var lumaMean: Float

    /// Color space the pipeline is operating in. Drives the shader's
    /// linearize/delinearize wrapping so the fitted k/pivot curve hits
    /// the same tonal location regardless of pipeline color space.
    public var colorSpace: DCRColorSpace

    /// Create a ``ContrastFilter`` with the given slider, scene mean
    /// luminance, and the pipeline's current color-space mode.
    public init(
        contrast: Float = 0,
        lumaMean: Float = 0.5,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.contrast = contrast
        self.lumaMean = lumaMean
        self.colorSpace = colorSpace
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRContrastFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(ContrastUniforms(
            contrast: contrast / 100.0,
            lumaMean: lumaMean,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// Declared fuse group (`.toneAdjustment`). See
    /// ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { .toneAdjustment }
}

/// Memory layout matches `constant ContrastUniforms& u [[buffer(0)]]`.
struct ContrastUniforms {
    /// `-1.0 ... +1.0`.
    var contrast: Float
    /// `0 ... 1`.
    var lumaMean: Float
    /// 1 = linear input; 0 = gamma-encoded.
    var isLinearSpace: UInt32
}
