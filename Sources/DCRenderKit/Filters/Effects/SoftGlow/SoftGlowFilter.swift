//
//  SoftGlowFilter.swift
//  DCRenderKit
//
//  Pro Mist / soft glow via Dual Kawase Bloom with resolution-adaptive
//  pyramid depth. Declarative MultiPassFilter graph with adaptive pass
//  count driven by input short side.
//

import Foundation

/// Soft-glow / Pro Mist effect using Dual Kawase Bloom
/// (Golubev, 2015 "Bandwidth-efficient rendering").
///
/// ## Algorithm
///
/// A multi-level Gaussian-like blur built from a downsample / upsample
/// pyramid with 2×2 box averaging on the way down and a 9-tap tent
/// filter on the way up. Compared to a straight Gaussian, Dual Kawase:
///   - Achieves equivalent visual blur in O(N) work (vs. O(N·σ) for
///     separable Gaussian at the same σ)
///   - Naturally progresses toward a ring-shaped PSF that matches how
///     optical flare glows (rather than a sharp Gaussian ball)
/// The first downsample additionally applies a smoothstep highlight
/// threshold so only bright regions contribute to the bloom.
///
/// Final composite is a Screen blend (`1 - (1-src)(1-bloom)`), which
/// is softer than additive and preserves high-luminance detail.
///
/// ## Dynamic pyramid depth (rules/spatial-params.md §2)
///
/// Level count adapts to the source resolution so the **visual** bloom
/// radius in points stays comparable across resolutions:
///
///     levels = max(3, ⌊log₂(shortSide / 135)⌋)
///
/// - 1080p (shortSide=1080): 3 levels — matches the historical fixed
///   pipeline for backward compatibility
/// - 4K      (shortSide=2160): 4 levels — one extra level absorbs the
///   extra resolution so the 1/Nth-resolution blur still corresponds
///   to roughly the same visual radius
/// - 8K      (shortSide=4320): 5 levels, etc.
///
/// Anchor 135px was chosen because it's the typical bottom-level size
/// of a 1080p pyramid at 3 levels (1080 / 2³ ≈ 135).
///
/// ## Pass count
///
/// Total passes = `2·levels + 1`:
///   - `levels` downsample passes (one bright-threshold + `levels-1` plain)
///   - `levels` upsample passes
///   - 1 final Screen blend
///
/// Identity at `strength ≤ 0.001` short-circuits to an empty graph.
public struct SoftGlowFilter: MultiPassFilter {

    /// Overall strength slider `0 ... 100`. Drives the final Screen-blend
    /// mix. Product-compressed by ×0.35 inside the final kernel.
    public var strength: Float

    /// Highlight threshold slider `0 ... 100`. Remapped to a smoothstep
    /// center of `0.3 + slider · 0.006`: slider=0 means broad bloom, 100
    /// means only the very brightest regions glow.
    public var threshold: Float

    /// Bloom radius slider `0 ... 100`. Scales the per-level tap offset
    /// (a ratio of the lower-level short side). Product-compressed from
    /// 0.002 (slider 0) to 0.006 (slider 100).
    public var bloomRadius: Float

    /// Create a ``SoftGlowFilter`` with strength, bright-threshold,
    /// and bloom-radius sliders.
    public init(strength: Float = 50, threshold: Float = 0, bloomRadius: Float = 25) {
        self.strength = strength
        self.threshold = threshold
        self.bloomRadius = bloomRadius
    }

    /// Declarative pass graph: bright threshold → pyramid downsample
    /// → pyramid upsample → Screen-blend composite.
    /// See ``MultiPassFilter/passes(input:)``.
    public func passes(input: TextureInfo) -> [Pass] {
        guard strength > 0.001 else { return [] }

        // FIXME(§8.6 Tier 2 archived): Threshold mapping `0.3 + slider ·
        // 0.6` (slider 0→100 maps to smoothstep center [0.3, 0.9]) and
        // offsetRatio mapping `0.002 + slider · 0.004` (slider 0→100 maps
        // to short-side fraction [0.002, 0.006]) are empirical hand-tuned
        // ranges. Neither was derived from an optical PSF target or bloom
        // physics; locked by Tier 4 snapshot approval once recorded.
        let thresholdMapped = 0.3 + (threshold / 100.0) * 0.6
        let offsetRatio = 0.002 + (bloomRadius / 100.0) * 0.004

        // Adaptive pyramid depth. See type-level doc.
        //
        // FIXME(§8.4 Audit.1): Anchor 135 px traces to "1080p ÷ 2³ ≈ 135"
        // — the choice preserves backward compatibility with the historical
        // 3-level fixed pipeline. This derivation is internally consistent
        // but its premise ("why 3 levels was right for 1080p") is itself
        // inherited, not validated against any optical PSF or bloom-radius
        // target. Industry reference for bloom pyramid depth (Unity HDRP /
        // Unreal / Blender) pending §8.4 Audit.1.
        let shortSide = input.shortSide
        let levels = max(3, Int(log2(Float(shortSide) / 135.0)))

        var passes: [Pass] = []

        // ── Downsample pyramid ──
        //
        // Level naming: d_1 = 1/2, d_2 = 1/4, ..., d_levels = 1/(2^levels).
        // The first pass applies the highlight threshold; subsequent
        // passes are plain 2×2 box averages.
        for level in 1...levels {
            let factor = Float(1) / Float(1 << level)
            let name = "d\(level)"
            if level == 1 {
                passes.append(.compute(
                    name: name,
                    kernel: "DCRSoftGlowBrightDownsample",
                    inputs: [.source],
                    output: .scaled(factor: factor),
                    uniforms: FilterUniforms(SoftGlowBrightUniforms(
                        threshold: thresholdMapped
                    ))
                ))
            } else {
                passes.append(.compute(
                    name: name,
                    kernel: "DCRSoftGlowDownsample",
                    inputs: [.named("d\(level - 1)")],
                    output: .scaled(factor: factor)
                ))
            }
        }

        // ── Upsample pyramid ──
        //
        // Level naming: u_1 = 1/(2^(levels-1)), u_2 = 1/(2^(levels-2)),
        // ..., u_levels = full resolution. Each upsample reads its
        // same-level downsample as current + the lower-level (or previous
        // upsample) as lower. The topmost upsample (full res) uses
        // addCurrent=0 to avoid re-adding the source colour before the
        // final Screen blend.
        for level in 1...levels {
            let outLevel = levels - level            // 0 == full resolution
            let uName = "u\(level)"

            let outputSpec: TextureSpec
            let currentInput: PassInput
            let lowerInput: PassInput
            let addCurrent: Float

            if outLevel == 0 {
                outputSpec = .sameAsSource
                currentInput = .source
                lowerInput = (level == 1) ? .named("d\(levels)") : .named("u\(level - 1)")
                addCurrent = 0.0
            } else {
                outputSpec = .scaled(factor: Float(1) / Float(1 << outLevel))
                currentInput = .named("d\(outLevel)")
                lowerInput = (level == 1) ? .named("d\(levels)") : .named("u\(level - 1)")
                addCurrent = 1.0
            }

            passes.append(.compute(
                name: uName,
                kernel: "DCRSoftGlowUpsample",
                inputs: [currentInput, lowerInput],
                output: outputSpec,
                uniforms: FilterUniforms(SoftGlowUpsampleUniforms(
                    offsetRatio: offsetRatio,
                    addCurrent: addCurrent
                ))
            ))
        }

        // ── Final composite ──
        //
        // Screen blend between source and the full-resolution bloom,
        // with strength ×0.35 product compression.
        passes.append(.final(
            kernel: "DCRSoftGlowComposite",
            inputs: [.source, .named("u\(levels)")],
            output: .sameAsSource,
            uniforms: FilterUniforms(SoftGlowCompositeUniforms(
                // FIXME(§8.6 Tier 2): × 0.35 Screen-blend-weight
                // compression (slider 100 → 0.35 mix). Hand-tuned for
                // "noticeable but not blown-out glow". Origin lost with
                // fitting pipeline. Note: user 2026-04-22 previously
                // retuned strength down to 35% from earlier higher
                // values after real-device evaluation — this reflects
                // a real perceptual ceiling, not arbitrary choice.
                // Validation: findings-and-plan.md §8.6 Tier 2.
                strength: (strength / 100.0) * 0.35
            ))
        ))

        return passes
    }
}

// MARK: - Uniform layouts

struct SoftGlowBrightUniforms {
    /// Smoothstep center `0.3 ... 0.9` for highlight extraction.
    var threshold: Float
}

struct SoftGlowUpsampleUniforms {
    /// Tap offset as a ratio of `min(lowerW, lowerH)` in pixels.
    var offsetRatio: Float
    /// `1.0` to accumulate current-level texture (pyramid combine path);
    /// `0.0` for the final level (pre-Screen-blend — we don't want
    /// source-level luminance double-counted before the composite pass).
    var addCurrent: Float
}

struct SoftGlowCompositeUniforms {
    /// Screen-blend mix weight `0 ... 0.35` (product-compressed).
    var strength: Float
}
