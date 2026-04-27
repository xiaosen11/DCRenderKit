//
//  SaturationFilter.swift
//  DCRenderKit
//
//  OKLCh-based uniform chroma scaling. See `docs/contracts/saturation.md`
//  for the contract; `Shaders/ColorGrading/Saturation/SaturationFilter.metal`
//  for the kernel.
//

import Foundation

/// Perceptually-uniform per-pixel saturation adjustment.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (colour grading, perception-based)
/// - Algorithm: linear sRGB → OKLab → OKLCh; multiply `C` by
///   `saturation`; clamp into gamut at constant `(L, h)`; OKLCh → OKLab
///   → linear sRGB.
///   - Reference: Ottosson (2020), *A perceptual color space for image
///     processing*. https://bottosson.github.io/posts/oklab/
///   - OKLab is adopted by CSS Color Level 4/5 since December 2021 and
///     is designed explicitly for "increasing the saturation of colors
///     while maintaining perceived hue and lightness". For the purpose
///     of uniform saturation scaling it out-performs Rec.709 luma
///     anchoring (non-perceptual) and CIELAB 1976 (blue-purple hue
///     drift). JzAzBz (darktable) would be a valid alternative but is
///     heavier; OKLab's CSS-standard status and simpler implementation
///     tip the balance.
///   - Gamut clamp: binary-search on `C` preserving `L` and `h`. See
///     `docs/contracts/saturation.md` for tolerances.
///
/// ## Parameter range
///
/// `saturation` is a direct chroma multiplier in `[0, 2]`:
/// - `0` = fully desaturated (OKLab `L` preserved; result is perceptual
///   grayscale)
/// - `1` = identity (no change)
/// - `2` = doubled chroma; high-chroma inputs may hit the gamut
///   boundary, in which case the clamp preserves hue and lightness
///   at the cost of chroma.
///
/// Identity at `saturation = 1` is exact (up to Float16 quantization).
///
/// ## Breaking change from pre-#77 implementation
///
/// The prior implementation used Rec.709 luma-anchored linear mix
/// (`mix(vec3(luma), rgb, s)`) which collapses to Rec.709 Y at
/// `saturation = 0`. The new implementation collapses to a gray with
/// the same OKLab `L` (perceptual lightness). Rec.709 `Y` and OKLab
/// `L` for the same pixel typically differ by <0.05 in linear units,
/// so the visual effect at `saturation = 0` is subtly different but
/// both are "perceptually valid" greys. Reference values for the
/// default saturation slider position remain unchanged (identity).
@available(iOS 18.0, *)
public struct SaturationFilter: FilterProtocol {

    /// Saturation multiplier. Range `0 ... 2`; identity at `1`.
    public var saturation: Float

    /// Create a ``SaturationFilter`` with the given chroma multiplier.
    ///
    /// `colorSpace` exists as a contract guard, not as a routing
    /// parameter: OKLab's perceptual transform (Ottosson 2020) is
    /// mathematically calibrated for **linear sRGB only**. Running
    /// the body on gamma-encoded values produces perceptually-wrong
    /// `L` and the gamut clamp can converge on near-black for
    /// chromatic pixels (the historical "脏黑斑" symptom). Rather
    /// than maintaining a perceptual-mode round-trip that would only
    /// hide misuse, this filter hard-fails when handed anything but
    /// `.linear` — surfacing the problem at the call site instead of
    /// the rendered output.
    ///
    /// If your pipeline runs in `.perceptual` mode (DigiCam parity),
    /// arrange a linearise → Saturation → re-encode wrap at the call
    /// site. Most pipelines run end-to-end in `.linear` (the SDK's
    /// default) so the parameter can be omitted.
    ///
    /// - Precondition: `colorSpace == .linear`. Anything else traps
    ///   in both Debug and Release.
    public init(
        saturation: Float = 1.0,
        colorSpace: DCRColorSpace = .linear
    ) {
        precondition(
            colorSpace == .linear,
            "SaturationFilter only supports .linear color space — OKLab " +
            "math is calibrated for linear sRGB and produces incorrect " +
            "perceptual L for gamma input. Got: \(colorSpace). To use " +
            "Saturation in a .perceptual pipeline, wrap the call with " +
            "explicit linearise / re-encode steps."
        )
        self.saturation = saturation
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRSaturationFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(SaturationUniforms(saturation: saturation))
    }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4.
    ///
    /// `wantsLinearInput = true` reflects the body's hard contract:
    /// OKLab math is defined for linear sRGB only, so this filter
    /// declares a strict linear-input requirement to VerticalFusion.
    /// It will not cluster with `wantsLinearInput: false` filters
    /// (Exposure / Contrast / WhiteBalance), which is correct — those
    /// internally do gamma-domain math and would feed gamma values
    /// across the cluster register hand-off.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRSaturationBody",
            uniformStructName: "SaturationUniforms",
            kind: .pixelLocal,
            wantsLinearInput: true,
            sourceText: BundledShaderSources.saturationFilter,
            sourceLabel: "SaturationFilter.metal"
        )
    }
}

/// Memory layout matches `constant SaturationUniforms& u [[buffer(0)]]`.
struct SaturationUniforms {
    /// `0 ... 2`, identity at `1`. Shader clamps.
    var saturation: Float
}
