//
//  WhiteBalanceFilter.swift
//  DCRenderKit
//
//  Kelvin-driven white balance via YIQ tint + Overlay warm-mix. Port of
//  Harbeth's C7WhiteBalance — behaviour-for-behaviour compatible so
//  consumers migrating off Harbeth see the same pixels.
//

import Foundation

/// Kelvin-driven white balance with independent tint axis.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (colour grading)
/// - **Tint** axis: operate in YIQ colour space on the Q channel
///   (green ↔ magenta axis). `ΔQ = tint/100 · 0.05226`, clamped to the
///   Q-axis gamut `±0.5226`. Because YIQ is a linear transform of RGB,
///   editing only Q keeps luma and the I (orange ↔ blue) axis
///   untouched, which is the defining property of a correct tint
///   control (no luma shift on skin).
/// - **Temperature** axis: Overlay-blend the tinted RGB with a warm
///   target `(0.93, 0.54, 0.0)` by a small coefficient derived from the
///   Kelvin offset. Piecewise linear in Kelvin because Kelvin-perceived
///   temperature is non-linear: a 1000 K step below 5000 K looks larger
///   than the same step above:
///     - below 5000 K: `0.0004 · (K - 5000)`
///     - above 5000 K: `0.00006 · (K - 5000)`
/// - Reference: the exact formulation ships in Harbeth's C7WhiteBalance.
///   We preserve it byte-for-byte to provide a drop-in replacement.
///
/// ## Parameter ranges
///
/// - `temperature` (Kelvin): `[4000, 8000]`, identity at `5000`.
/// - `tint`: `[-200, +200]`, `-200` = very green, `+200` = very magenta,
///   identity at `0`.
///
/// Identity at `(temperature=5000, tint=0)` is exact.
public struct WhiteBalanceFilter: FilterProtocol {

    /// Colour temperature in Kelvin. Range `4000 ... 8000`; identity at
    /// `5000`. Values below 5000 cool the image toward blue; above 5000
    /// warm toward orange.
    public var temperature: Float

    /// Tint axis on the Q (green ↔ magenta) component. Range
    /// `-200 ... +200`; identity at `0`. Negative shifts green, positive
    /// shifts magenta.
    public var tint: Float

    /// Color space the input texture is in. The YIQ mix + warm-overlay
    /// fit was done in gamma space; in `.linear` mode the shader wraps
    /// the fit with linearize/delinearize for visual parity.
    public var colorSpace: DCRColorSpace

    public init(
        temperature: Float = 5000,
        tint: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.temperature = temperature
        self.tint = tint
        self.colorSpace = colorSpace
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRWhiteBalanceFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(WhiteBalanceUniforms(
            temperature: temperature,
            tint: tint,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    public static var fuseGroup: FuseGroup? { .colorGrading }
}

/// Memory layout matches `constant WhiteBalanceUniforms& u [[buffer(0)]]`.
struct WhiteBalanceUniforms {
    /// Kelvin in `4000 ... 8000`. Shader clamps.
    var temperature: Float
    /// Tint in `-200 ... +200`. Shader clamps.
    var tint: Float
    /// 1 = linear input; 0 = gamma-encoded.
    var isLinearSpace: UInt32
}
