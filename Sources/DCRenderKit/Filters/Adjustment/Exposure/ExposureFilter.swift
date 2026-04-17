//
//  ExposureFilter.swift
//  DCRenderKit
//
//  Exposure adjustment filter. Ported from DigiCam's self-developed kernel.
//

import Foundation

/// Exposure adjustment with commercial-grade tone mapping on the positive
/// side and display-space power curve on the negative side.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Positive direction: Extended Reinhard in linear (gamma 2.2) space
///   - Reference: Reinhard et al., *Photographic Tone Reproduction for
///     Digital Images*, SIGGRAPH 2002
///   - Why Reinhard: preserves highlight rolloff rather than clipping,
///     which matches Lightroom's exposure behavior on bright regions
///   - Alternative considered: pure linear gain (too harsh, clips highlights
///     above +0.5 EV)
/// - Negative direction: `A * x^gamma + B * x` in display space
///   - Why compound: a pure power curve under-compensated the dark tones
///     compared to Lightroom's ACR3 S-curve shoulder; adding a linear term
///     models the shoulder lift. MSE dropped 10.53 → 2.82 over three
///     Lightroom-exported reference scenes.
///
/// ## Parameter range
///
/// `exposure` is a slider value in `-100 ... +100`. Internally compressed
/// by 0.7 so the perceptual extreme matches the product decision (slider
/// ±100 represents 70% of the raw fit). Identity at 0.
public struct ExposureFilter: FilterProtocol {

    /// Exposure slider in stops-like units. Range `-100 ... +100`.
    /// Positive brightens with highlight rolloff; negative darkens with
    /// power-curve shoulder.
    public var exposure: Float

    public init(exposure: Float = 0) {
        self.exposure = exposure
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRExposureFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(ExposureUniforms(exposure: exposure / 100.0))
    }

    public static var fuseGroup: FuseGroup? { .toneAdjustment }
}

/// Memory layout matches `constant ExposureUniforms& u [[buffer(0)]]`
/// declared in `ExposureFilter.metal`.
struct ExposureUniforms {
    /// Slider value remapped to `-1.0 ... +1.0`. Shader applies its own
    /// clamp and ×0.7 product compression.
    var exposure: Float
}
