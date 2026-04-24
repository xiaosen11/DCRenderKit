//
//  ClarityFilter.swift
//  DCRenderKit
//
//  Mid-frequency contrast enhancement via guided filter base/detail
//  decomposition. Shares the three guided filter sub-kernels with
//  HighlightShadowFilter. Ported from DigiCam.
//

import Foundation

/// Mid-frequency local contrast ("clarity") via guided filter base/detail
/// decomposition.
///
/// ## Algorithm
///
/// 1. Extract an edge-preserving base via Fast Guided Filter
///    (reuses `HighlightShadowFilter`'s 3 sub-kernels).
/// 2. `detail = original - base` — the removed mid-frequency signal.
/// 3. **Positive intensity**: `output = original + detail · intensity ·
///    gain`. Amplifies texture and micro-contrast without affecting
///    overall tonal balance (tonal balance is in `base`, unchanged).
/// 4. **Negative intensity**: `output = mix(original, base, |intensity|)`.
///    Blends toward the smooth base — produces a soft, painterly look
///    without blurring edges.
///
/// Using guided filter instead of a Gaussian/bilateral gives two wins:
///   - Edge-aware base ⇒ no halos around high-contrast edges when
///     amplifying detail
///   - Cheap compared to a multi-scale Laplacian pyramid (5 dispatches
///     regardless of image size)
///
/// ## Parameters
///
/// - `eps = 0.005` (tighter than HighlightShadow's 0.01 because clarity
///   benefits from preserving smaller-scale features in the base)
/// - `p = 0.019` (larger box than HighlightShadow's 0.012 because
///   clarity operates over a wider base window)
/// - Product compression: raw `intensity/100` × 0.75 to keep extreme
///   slider from feeling harsh.
///
/// Identity at `intensity = 0` short-circuits to an empty pass graph.
public struct ClarityFilter: MultiPassFilter {

    /// Clarity slider `-100 ... +100`. Positive amplifies mid-frequency
    /// detail, negative smooths toward the base.
    public var intensity: Float

    /// Color space the input texture is in. Drives the final-pass wrap:
    /// `detail = original - base` is space-dependent, and the product-
    /// compression constants (×1.5 positive, ×0.7 negative) were fit
    /// for gamma-space detail. In `.linear` mode the shader un-linearizes
    /// both signals, computes detail in gamma space, applies the fit,
    /// then re-linearizes.
    public var colorSpace: DCRColorSpace

    /// Create a ``ClarityFilter`` with the given intensity slider and
    /// the pipeline's current color-space mode.
    public init(
        intensity: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.intensity = intensity
        self.colorSpace = colorSpace
    }

    /// Declarative pass graph: downsample → computeAB → smoothAB →
    /// computeBase → applyDetail. See ``MultiPassFilter/passes(input:)``.
    public func passes(input: TextureInfo) -> [Pass] {
        let normalized = intensity / 100.0
        guard abs(normalized) > 0.001 else { return [] }

        // p anchor: radius ≈ 8 at √(480·360) ≈ 416 → p = 8/416 ≈ 0.019.
        //
        // FIXME(§8.6 Tier 2 archived): Anchor radius ≈ 8 at 480×360
        // (1.9 % short side) is an empirical hand-tune, larger than
        // HighlightShadow's 1.2 % because Clarity wants a wider base
        // window so more mid-frequency detail lands in the residual.
        // 1.9 % falls inside Cambridge in Colour's 30-100 px "local
        // contrast enhancement" band at 4K and above; at 1080p it
        // lands slightly below the low end.
        let quarterW = max(input.width / 4, 1)
        let quarterH = max(input.height / 4, 1)
        let p: Float = 0.019
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
                    // eps = 0.005 is tighter than HighlightShadow's
                    // 0.01 — the design intent is a sharper base so
                    // more mid-frequency detail lands in the residual
                    // available for amplification. Falls inside the
                    // 0.001-0.1 range guided-filter literature cites.
                    eps: 0.005,
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
                name: "base",
                kernel: "DCRClarityComputeBase",
                inputs: [.source, .named("smooth")],
                output: .sameAsSource
            ),
            .final(
                kernel: "DCRClarityApply",
                inputs: [.source, .named("base")],
                output: .sameAsSource,
                uniforms: FilterUniforms(ClarityUniforms(
                    // FIXME(§8.6 Tier 2): × 0.75 Swift-side compression
                    // (applied before shader's own × 1.5 positive or × 0.7
                    // negative). Effective slider 100 maps to 0.75 × 1.5 =
                    // 1.125 positive gain or 0.75 × 0.7 = 0.525 negative
                    // blend. The two-stage compression (Swift + shader) is
                    // inherited and the split has no principled reason —
                    // could be combined into one factor. Origin lost.
                    // Validation: findings-and-plan.md §8.6 Tier 2.
                    intensity: normalized * 0.75,   // product compression
                    isLinearSpace: isLinear
                ))
            ),
        ]
    }
}

/// Memory layout matches `constant ClarityUniforms& u [[buffer(0)]]`.
struct ClarityUniforms {
    /// Clarity slider in `-1 ... +1`, product-compressed by 0.75.
    var intensity: Float
    /// 1 = linear input; 0 = gamma-encoded.
    var isLinearSpace: UInt32
}
