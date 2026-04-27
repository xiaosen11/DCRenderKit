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

    /// Color space the input texture is encoded in. Drives the
    /// shader's gamma-linear conversion:
    ///
    ///   - ``DCRColorSpace/perceptual``: input is sRGB-gamma encoded
    ///     (raw `bgra8Unorm` source — typically a JPEG/PNG decoded
    ///     into a non-`_srgb` texture). The shader linearises with
    ///     IEC 61966-2-1 piecewise sRGB before running OKLab math,
    ///     then re-encodes on output.
    ///   - ``DCRColorSpace/linear``: input is already linear
    ///     scene-light (texture loaded with `.SRGB: true`, or
    ///     upstream filter produced linear values). Shader skips the
    ///     conversion and runs OKLab on the values directly.
    ///
    /// **Why this parameter exists**: OKLab's perceptual-uniformity
    /// (Ottosson 2020) is calibrated for **linear sRGB**. Feeding
    /// gamma-encoded values to `DCRLinearSRGBToOKLab` produces a
    /// perceptually-wrong `L`: the cube-root pre-shaping and
    /// downstream gamut clamp converge on too-low `L` for chromatic
    /// pixels, surfacing as the "脏黑斑 / dirty black blob" symptom
    /// users observed in edit-preview chains where the source was
    /// loaded perceptually-encoded. Defaults to
    /// ``DCRenderKit/defaultColorSpace`` so the SDK-wide mode drives
    /// the filter without consumer plumbing.
    public var colorSpace: DCRColorSpace

    /// Create a ``SaturationFilter`` with the given chroma multiplier
    /// and the pipeline's current color-space mode.
    public init(
        saturation: Float = 1.0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.saturation = saturation
        self.colorSpace = colorSpace
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRSaturationFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(SaturationUniforms(
            saturation: saturation,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4.
    ///
    /// `wantsLinearInput = false` matches the pattern Exposure /
    /// Contrast / WhiteBalance use: the body internally branches on
    /// `isLinearSpace` and self-converts when the pipeline runs in
    /// perceptual mode, so VerticalFusion can cluster Saturation
    /// alongside the other tone operators without an intermediate
    /// gamma round-trip.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRSaturationBody",
            uniformStructName: "SaturationUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceText: BundledShaderSources.saturationFilter,
            sourceLabel: "SaturationFilter.metal"
        )
    }
}

/// Memory layout matches `constant SaturationUniforms& u [[buffer(0)]]`.
struct SaturationUniforms {
    /// `0 ... 2`, identity at `1`. Shader clamps.
    var saturation: Float
    /// 1 = input is linear-light; 0 = input is perceptually-gamma-encoded.
    /// Written as UInt32 to match Metal `uint` layout alignment.
    var isLinearSpace: UInt32
}
