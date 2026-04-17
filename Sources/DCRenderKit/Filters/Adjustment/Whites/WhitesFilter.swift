//
//  WhitesFilter.swift
//  DCRenderKit
//
//  Whites adjustment — per-channel weighted-parabola for positive,
//  luma-ratio for negative. Ported from DigiCam.
//

import Foundation

/// Whites adjustment targeting highlight-region response separately from
/// shadow-region response.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Positive direction: per-channel `y = x * (1 + k * x * (1-x)^b)`
///   - Weighted parabola — the `x * (1-x)^b` envelope concentrates effect
///     in highlights (peaks near `x ≈ 1 / (b+1)` and vanishes at 0 and 1).
///   - `k` and `b` LUT-interpolated against image mean luma (3 anchor
///     scenes). Why LUT: single-parameter families failed cross-scene
///     (90× MSE regression vs. ad-hoc baseline); LUT closes the gap while
///     remaining monotonic and clampable.
/// - Negative direction: luma-ratio `y = x * (1 + k * x^a * (1-x)^b)` on
///   scene luma, then rescale RGB by `y / luma`.
///   - Why luma-ratio: negative pull on highlights needs to dim a bright
///     neutral region without introducing color cast; operating on luma
///     and back-ratioing to RGB preserves chroma.
/// - Alternatives considered: WeightedParab / ParabolicRatio / QuadRatio /
///   PowerLaw / CubicPivot. Weighted parabola won on positive side
///   (MSE 1.02 vs 185 for PowerLaw); luma-ratio won on negative.
///
/// ## Parameter range
///
/// - `whites`: slider in `-100 ... +100`
/// - `lumaMean`: pre-computed display-space luma mean of the source,
///   `[0, 1]`. LUT interpolation is edge-clamped outside `[0.29, 0.60]`.
///
/// Identity at `whites = 0` is exact.
public struct WhitesFilter: FilterProtocol {

    /// Whites slider. Range `-100 ... +100`.
    public var whites: Float

    /// Image mean luma in display space, `[0, 1]`.
    public var lumaMean: Float

    public init(whites: Float = 0, lumaMean: Float = 0.5) {
        self.whites = whites
        self.lumaMean = lumaMean
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRWhitesFilter")
    }

    public var uniforms: FilterUniforms {
        let (k100, b) = Self.lutInterpolate(lumaMean: lumaMean)
        return FilterUniforms(WhitesUniforms(
            whites: whites / 100.0,
            k100: k100,
            b: b
        ))
    }

    public static var fuseGroup: FuseGroup? { .toneAdjustment }

    // MARK: - LUT (positive side only)

    // Three anchor scenes against Lightroom +100 ground truth. Values
    // below are fit × 0.7 (product decision: slider ±100 uses 70% of raw
    // magnitude to keep extreme feel within perceptual comfort).
    private static let lutMeans: [Float] = [0.2877, 0.3995, 0.6004]
    private static let lutK100:  [Float] = [2.3215, 5.4223, 0.6251]
    private static let lutB:     [Float] = [1.3881, 1.9729, 0.9875]

    /// Piecewise-linear interpolate (k100, b) by mean luma. Edge-clamped.
    static func lutInterpolate(lumaMean: Float) -> (k100: Float, b: Float) {
        let m = lumaMean
        if m <= lutMeans[0] { return (lutK100[0], lutB[0]) }
        if m >= lutMeans[2] { return (lutK100[2], lutB[2]) }
        for i in 0..<(lutMeans.count - 1) where m >= lutMeans[i] && m <= lutMeans[i + 1] {
            let t = (m - lutMeans[i]) / (lutMeans[i + 1] - lutMeans[i])
            return (
                lutK100[i] + t * (lutK100[i + 1] - lutK100[i]),
                lutB[i] + t * (lutB[i + 1] - lutB[i])
            )
        }
        return (lutK100[2], lutB[2])
    }
}

/// Memory layout matches `constant WhitesUniforms& u [[buffer(0)]]`.
struct WhitesUniforms {
    /// `-1.0 ... +1.0`. Shader dead-zones around 0 for exact identity.
    var whites: Float
    /// Interpolated curvature coefficient for positive branch.
    var k100: Float
    /// Interpolated highlight-concentration exponent for positive branch.
    var b: Float
}
