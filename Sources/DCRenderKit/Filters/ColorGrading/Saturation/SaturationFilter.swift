//
//  SaturationFilter.swift
//  DCRenderKit
//
//  Rec.709 luma-anchored saturation. Port of Harbeth's C7Saturation with
//  the standard DCRenderKit typed-uniforms contract.
//

import Foundation

/// Per-pixel saturation adjustment anchored on Rec.709 luminance.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (colour grading)
/// - Algorithm: `out = mix(luma, rgb, saturation)` with Rec.709 weights
///   `(0.2125, 0.7154, 0.0721)`.
///   - Reference: Poynton, *Digital Video and HD*, §6.8 (luma coding
///     coefficients). Same formulation used by Core Image's
///     `CIColorControls.saturation`, GPUImage's `GPUImageSaturationFilter`,
///     and Harbeth's `C7Saturation`.
///   - Why luma anchor (not HSL `.s`): HSL saturation clips at the corner
///     of the gamut cube and produces colour shifts on high-chroma pixels.
///     Luma-anchored mix scales linearly toward grayscale and preserves
///     hue exactly.
///
/// ## Parameter range
///
/// `saturation` is a direct multiplier in `[0, 2]`:
/// - `0` = fully desaturated (grayscale)
/// - `1` = identity (no change)
/// - `2` = doubled chroma distance from luma (common clip point)
///
/// Identity at `saturation = 1` is exact.
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
