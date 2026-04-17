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

    public init(intensity: Float = 0) {
        self.intensity = intensity
    }

    public func passes(input: TextureInfo) -> [Pass] {
        let normalized = intensity / 100.0
        guard abs(normalized) > 0.001 else { return [] }

        // p anchor: radius ≈ 8 at √(480·360) ≈ 416 → p = 8/416 ≈ 0.019.
        let quarterW = max(input.width / 4, 1)
        let quarterH = max(input.height / 4, 1)
        let p: Float = 0.019
        let radiusX = max((Float(quarterW) * p).rounded(), 1.0)
        let radiusY = max((Float(quarterH) * p).rounded(), 1.0)

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
                    intensity: normalized * 0.75   // product compression
                ))
            ),
        ]
    }
}

/// Memory layout matches `constant ClarityUniforms& u [[buffer(0)]]`.
struct ClarityUniforms {
    /// Clarity slider in `-1 ... +1`, product-compressed by 0.75.
    var intensity: Float
}
