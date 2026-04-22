//
//  VibranceFilter.swift
//  DCRenderKit
//
//  Selective saturation — boosts already-unsaturated colours while
//  leaving high-chroma regions relatively untouched. Port of Harbeth's
//  C7Vibrance, which itself ports GPUImage's classic vibrance shader.
//

import Foundation

/// "Vibrance" — perceptually smarter saturation that scales stronger on
/// undersaturated pixels than on already-saturated ones.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (colour grading)
/// - Algorithm: `amount = (max(RGB) - mean(RGB)) · (-3·vibrance)`,
///   `out = mix(rgb, vec3(max(RGB)), amount)`.
///   - `max - mean` is a cheap saturation proxy: ≈ 0 on grayscale pixels,
///     larger on high-chroma pixels.
///   - Multiplying by `-vibrance` means the mix blends *toward* the
///     max-channel (saturating) when vibrance is positive, away from it
///     (desaturating) when negative.
///   - Factor `3` is GPUImage's historical default that produces a
///     perceptually balanced curve matching the consumer-app reference's
///     vibrance slider behavior.
///   - Reference: Brad Larson, *GPUImage* (2012), `VibranceFilter.fsh`.
///     Same shader shipped as Harbeth's C7Vibrance.
///
/// ## Parameter range
///
/// `vibrance` in `[-1.2, +1.2]`:
/// - `0` = identity (no change)
/// - Positive = selective saturation boost (protects saturated pixels)
/// - Negative = selective desaturation (affects colourful regions more)
///
/// Identity at `vibrance = 0` is exact (amount factor collapses to 0).
public struct VibranceFilter: FilterProtocol {

    /// Vibrance slider. Range `-1.2 ... +1.2`; identity at `0`.
    public var vibrance: Float

    public init(vibrance: Float = 0.0) {
        self.vibrance = vibrance
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRVibranceFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(VibranceUniforms(vibrance: vibrance))
    }

    public static var fuseGroup: FuseGroup? { .colorGrading }
}

/// Memory layout matches `constant VibranceUniforms& u [[buffer(0)]]`.
struct VibranceUniforms {
    /// `-1.2 ... +1.2`. Shader clamps.
    var vibrance: Float
}
