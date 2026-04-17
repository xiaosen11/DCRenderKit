//
//  BlacksFilter.swift
//  DCRenderKit
//
//  Blacks adjustment — per-channel `model_ka`. Ported from DigiCam.
//

import Foundation

/// Blacks adjustment concentrating effect in the shadow region via a
/// fixed-parameter per-channel curve.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Algorithm: `y = x * (1 + k * (1-x)^a)`, per-channel
///   - The `(1-x)^a` envelope peaks near `x = 0` and fades to 0 at `x = 1`,
///     so the multiplicative deviation is concentrated in shadows.
/// - Why fixed parameters (no LUT): cross-scene fit on 3 Lightroom
///   references produced spread `k: 4%`, `a: 1%`. The per-scene gain from
///   a LUT is below the MSE noise floor, so fixed parameters are
///   justified and halve the per-frame Swift work.
/// - Alternatives considered: `model_ka / weighted parabola / power law /
///   model_kb_mirror`. `model_ka` produced MSE 0.63 at +100 bridge; next
///   best (weighted parabola) was 1.15.
///
/// ## Parameter range
///
/// `blacks` is `-100 ... +100`. Identity at 0.
public struct BlacksFilter: FilterProtocol {

    /// Blacks slider. Range `-100 ... +100`.
    public var blacks: Float

    public init(blacks: Float = 0) {
        self.blacks = blacks
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRBlacksFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(BlacksUniforms(blacks: blacks / 100.0))
    }

    public static var fuseGroup: FuseGroup? { .toneAdjustment }
}

/// Memory layout matches `constant BlacksUniforms& u [[buffer(0)]]`.
struct BlacksUniforms {
    /// `-1.0 ... +1.0`.
    var blacks: Float
}
