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
public struct SaturationFilter: FilterProtocol {

    /// Saturation multiplier. Range `0 ... 2`; identity at `1`.
    public var saturation: Float

    public init(saturation: Float = 1.0) {
        self.saturation = saturation
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRSaturationFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(SaturationUniforms(saturation: saturation))
    }

    public static var fuseGroup: FuseGroup? { .colorGrading }
}

/// Memory layout matches `constant SaturationUniforms& u [[buffer(0)]]`.
struct SaturationUniforms {
    /// `0 ... 2`, identity at `1`. Shader clamps.
    var saturation: Float
}
