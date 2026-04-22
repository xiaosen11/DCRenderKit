//
//  ContrastFilter.swift
//  DCRenderKit
//
//  Contrast adjustment with luma-mean adaptive S-curve. Ported from DigiCam.
//

import Foundation

/// Contrast adjustment driven by a cubic pivot curve whose steepness and
/// crossover point adapt to the image's mean luminance.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Algorithm: cubic pivot curve `y = x + k * x * (1-x) * (x-pivot)`
///   - Per-channel in display space, clamped to `[0, 1]`
///   - `k = (-0.356 * lumaMean + 2.289) * contrast` (slope control)
///   - `pivot = 0.381 * lumaMean + 0.377` (crossover control)
/// - Why cubic pivot: compared against sigmoid / piecewise-power / parabolic
///   pivot families on 3 Lightroom-exported scenes (luma means 0.29 / 0.40 /
///   0.60), the cubic pivot family produced the lowest cross-scene average
///   MSE (≈ 52.1) with only 2 adaptive coefficients.
/// - Why adapt to lumaMean: bright scenes tolerate steeper slopes than dark
///   scenes before dark-region crush; a single fixed curve over-compresses
///   shadows on high-key content and blows highlights on low-key content.
///
/// ## Parameter range
///
/// - `contrast`: slider in `-100 ... +100`
/// - `lumaMean`: pre-computed average display-space luma of the source,
///   expected in `[0.05, 0.95]`. Consumers typically obtain it via a single
///   reduction pass (MPS image statistics) before running the filter.
///
/// Identity at `contrast = 0` (k collapses to 0, curve degenerates to y = x).
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

    public init(
        contrast: Float = 0,
        lumaMean: Float = 0.5,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.contrast = contrast
        self.lumaMean = lumaMean
        self.colorSpace = colorSpace
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRContrastFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(ContrastUniforms(
            contrast: contrast / 100.0,
            lumaMean: lumaMean,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

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
