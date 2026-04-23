//
//  HighlightShadowFilter.swift
//  DCRenderKit
//
//  Highlight / shadow tone control via Fast Guided Filter base
//  extraction. Declarative MultiPassFilter pass graph with 5 compute
//  kernels (downsample → ab → smooth → ratio → apply).
//

import Foundation

/// Tonal control of highlights and shadows with edge-preserving base
/// extraction via Fast Guided Filter (He & Sun, 2015).
///
/// ## Algorithm
///
/// Both sliders operate on a smoothed base luminance (recovered by a
/// 4×-downsampled guided filter), not raw pixel luminance. This avoids
/// the "halo around edges" failure mode of a naive per-pixel tone curve:
/// bright skies next to dark mountains don't bleed into each other,
/// because the guided filter's edge-aware smoothing keeps the two
/// regions' baseLuma separate.
///
/// ## Pass graph (5 passes)
///
/// 1. **downsample** (`DCRGuidedDownsampleLuma`) — 4× downsample +
///    per-pixel luma and luma². Produces a low-res `(luma, luma²)` RG
///    texture used by steps 2 and 3.
/// 2. **ab** (`DCRGuidedComputeAB`) — compute guided filter coefficients
///    `(a, b)` at low resolution with `eps = 0.01` (favors broad base).
/// 3. **smooth** (`DCRGuidedSmoothAB`) — box-filter smoothing of `(a, b)`.
/// 4. **ratio** (`DCRGuidedApplyRatio` — this filter's unique kernel) —
///    bilinearly upsample `(a, b)` to full res, compute per-pixel
///    `baseLuma = a·I + b`, then combine with the two sliders via
///    smoothstep'd weight windows. Emits a per-pixel `ratio` value.
/// 5. **final** (`DCRHighlightShadowApply`) — multiply original RGB by
///    `ratio` and apply a mild saturation compensation.
///
/// ## Spatial parameters (rules/spatial-params.md §2)
///
/// `radiusX/Y` are image-structure parameters: they scale proportionally
/// to the quarter-resolution texture dimensions so the smoothing footprint
/// covers a fixed percentage of the image regardless of resolution.
///
/// Identity at `highlights == 0 && shadows == 0` short-circuits to an
/// empty pass graph — the framework passes the source through unchanged.
public struct HighlightShadowFilter: MultiPassFilter {

    /// Highlight slider, `-100 ... +100`. Positive recovers highlight
    /// detail, negative boosts highlights.
    public var highlights: Float

    /// Shadow slider, `-100 ... +100`. Positive opens up shadows,
    /// negative deepens shadows.
    public var shadows: Float

    /// Color space the input texture is in. Drives both shader branches:
    /// the smoothstep windows against `baseLuma` and the `ratio` multiply
    /// + saturation-compensation step are all calibrated in gamma space.
    /// In `.linear` mode the shader wraps both with un-linearize /
    /// re-linearize so midtones get the expected highlight / shadow
    /// response (the direct fix for F3's "对高光暗部不够敏感, 缺层次感").
    public var colorSpace: DCRColorSpace

    public init(
        highlights: Float = 0,
        shadows: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.highlights = highlights
        self.shadows = shadows
        self.colorSpace = colorSpace
    }

    public func passes(input: TextureInfo) -> [Pass] {
        // Identity short-circuit (dead-zone matches shader side).
        let h = highlights / 100.0
        let s = shadows / 100.0
        guard abs(h) > 0.001 || abs(s) > 0.001 else { return [] }

        // Guided-filter box radius scales with quarter-texture dimensions.
        // Anchor: radius ≈ 5 at √(480·360) ≈ 416 → p = 5/416 ≈ 0.012.
        // Scaled independently on X and Y so box-coverage ratio holds
        // under extreme aspect ratios.
        //
        // FIXME(§8.6 Tier 2 archived): Anchor radius ≈ 5 at 480×360 is
        // an empirical hand-tune chosen to give HighlightShadow a
        // "broad base" feel without haloing common edges. Falls inside
        // the 1-5 % short-side range Eilertsen et al. 2017 TMO survey
        // §4 cites for edge-preserving base extractors (the 1.2 % value
        // lands at the low end). Halo behaviour validated by contract
        // C.4 in `docs/contracts/highlight_shadow.md`.
        let quarterW = max(input.width / 4, 1)
        let quarterH = max(input.height / 4, 1)
        let p: Float = 0.012
        let radiusX = max((Float(quarterW) * p).rounded(), 1.0)
        let radiusY = max((Float(quarterH) * p).rounded(), 1.0)

        let isLinear: UInt32 = colorSpace == .linear ? 1 : 0

        return [
            .compute(
                name: "downsample",
                kernel: "DCRGuidedDownsampleLuma",
                inputs: [.source],
                output: .scaled(factor: 0.25)
            ),
            .compute(
                name: "ab",
                kernel: "DCRGuidedComputeAB",
                inputs: [.named("downsample")],
                output: .scaled(factor: 0.25),
                uniforms: FilterUniforms(DCRGuidedComputeABUniforms(
                    // eps = 0.01 matches the MATLAB `imguidedfilter`
                    // default for `[0, 1]` double images and the step-
                    // edge example in He & Sun 2015 (Fast Guided
                    // Filter). Larger eps → smoother base, smaller eps
                    // → sharper edge preservation; the 0.01 value is
                    // academic/industry default, not a hand-tune.
                    eps: 0.01,
                    radiusX: radiusX,
                    radiusY: radiusY
                ))
            ),
            .compute(
                name: "smooth",
                kernel: "DCRGuidedSmoothAB",
                inputs: [.named("ab")],
                output: .scaled(factor: 0.25),
                uniforms: FilterUniforms(DCRGuidedSmoothABUniforms(
                    radiusX: radiusX,
                    radiusY: radiusY
                ))
            ),
            .compute(
                name: "ratio",
                kernel: "DCRGuidedApplyRatio",
                inputs: [.source, .named("smooth")],
                output: .sameAsSource,
                uniforms: FilterUniforms(HighlightShadowRatioUniforms(
                    highlights: h,
                    shadows: s,
                    isLinearSpace: isLinear
                ))
            ),
            .final(
                kernel: "DCRHighlightShadowApply",
                inputs: [.source, .named("ratio")],
                output: .sameAsSource,
                uniforms: FilterUniforms(HighlightShadowApplyUniforms(
                    isLinearSpace: isLinear
                ))
            ),
        ]
    }
}

/// Memory layouts that match shader uniform structs in
/// `GuidedFilter.metal` and `HighlightShadowFilter.metal`.
struct DCRGuidedComputeABUniforms {
    var eps: Float
    var radiusX: Float
    var radiusY: Float
}

struct DCRGuidedSmoothABUniforms {
    var radiusX: Float
    var radiusY: Float
}

struct HighlightShadowRatioUniforms {
    /// Highlight slider normalized to `-1 ... +1`.
    var highlights: Float
    /// Shadow slider normalized to `-1 ... +1`.
    var shadows: Float
    /// 1 = linear input (un-linearize baseLuma for smoothstep windows);
    /// 0 = gamma input (native domain of window anchors).
    var isLinearSpace: UInt32
}

struct HighlightShadowApplyUniforms {
    /// Carries the same `isLinearSpace` flag as the ratio uniforms so
    /// the apply pass can wrap the ratio multiply + saturation
    /// compensation in gamma space.
    var isLinearSpace: UInt32
}
