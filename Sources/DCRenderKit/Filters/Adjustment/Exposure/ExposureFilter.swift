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
///     which matches the consumer-app reference's exposure behavior on
///     bright regions
///   - Alternative considered: pure linear gain (too harsh, clips highlights
///     above +0.5 EV)
/// - Negative direction: `A * x^gamma + B * x` in display space
///   - Why compound: a pure power curve under-compensated the dark tones
///     compared to the consumer-app reference's S-curve shoulder; adding
///     a linear term models the shoulder lift. MSE dropped 10.53 → 2.82
///     over three reference scenes exported in gamma space.
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

    public init(
        exposure: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.exposure = exposure
        self.colorSpace = colorSpace
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRExposureFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(ExposureUniforms(
            exposure: exposure / 100.0,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    public static var fuseGroup: FuseGroup? { .toneAdjustment }
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
