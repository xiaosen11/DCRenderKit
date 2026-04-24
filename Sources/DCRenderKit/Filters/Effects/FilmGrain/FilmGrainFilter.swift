//
//  FilmGrainFilter.swift
//  DCRenderKit
//
//  Film-grain noise overlay with configurable density, roughness,
//  chromaticity, and pixel-accurate grain size. Ported from DigiCam.
//

import Foundation

/// Film-grain noise overlay driven by a triangular-distributed pseudo-
/// random field, composited onto the source via symmetric SoftLight.
///
/// ## Model form justification
///
/// - Type: 2D neighborhood (block-quantized noise; no neighbor samples
///   but uses per-block center luma)
/// - Noise: sin-trick pseudo-random in `[-1, 1]`, shaped by `pow(|n|, p)`
///   where `p = mix(2.0, 0.5, roughness)`. Low roughness concentrates
///   noise near zero (soft grain), high roughness produces near-uniform
///   distribution (coarse grain).
/// - Blend: **symmetric SoftLight** — derived by perfectly compensating
///   Photoshop's asymmetric SoftLight so both darken and lighten
///   directions use the same formula:
///     `result = base + (2·blend - 1) · base · (1 - base)`
///   This eliminates the color shift that asymmetric SoftLight introduces
///   when dense noise is averaged over a region.
///   - Alternatives considered: overlay (harsher), linear light (over-
///     amplifies noise in shadows), multiply (not symmetric around 0.5).
///
/// ## Spatial parameter (rules/spatial-params.md §1)
///
/// `grainSize` is a visual-texture parameter. Grain must look the same
/// size in pt on screen across capture / editing / export. Consumers
/// inject `grainSize = 1.5pt * pixelsPerPoint` (the product-tuned
/// constant; see `docs/metal-engine-plan.md §5.4`).
///
/// Identity at `density = 0` is exact (dead-zone short-circuit).
@available(iOS 18.0, *)
public struct FilmGrainFilter: FilterProtocol {

    /// Noise amplitude `0 ... 1` — offset from the SoftLight neutral
    /// point `0.5`. Internally compressed by the shader's `±0.144`
    /// multiplier so slider 1.0 is not overwhelming.
    public var density: Float

    /// Grain roughness `0 ... 1`. `0` = soft grain (low-frequency noise
    /// concentrated near zero), `1` = coarse grain (near-uniform
    /// distribution).
    public var roughness: Float

    /// Grain chromaticity `0 ... 1`. `0` = monochrome grain (all channels
    /// share one noise value), `1` = fully independent R/G/B noise.
    public var chromaticity: Float

    /// Grain size in **pixels of the current texture**. For visual
    /// consistency across display contexts, pass
    /// `1.5pt * pixelsPerPoint`. Minimum effective value is 1.
    public var grainSize: Float

    /// Create a ``FilmGrainFilter`` with the four sliders and a
    /// `pixelsPerPoint`-scaled grain size.
    public init(
        density: Float = 0,
        roughness: Float = 0,
        chromaticity: Float = 0,
        grainSize: Float = 9.0
    ) {
        self.density = density
        self.roughness = roughness
        self.chromaticity = chromaticity
        self.grainSize = grainSize
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRFilmGrainFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(FilmGrainUniforms(
            density: density,
            grainSize: grainSize,
            roughness: roughness,
            chromaticity: chromaticity
        ))
    }

    /// Declared fuse group (`nil` — grain is not fusable).
    /// See ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { nil }
}

/// Memory layout matches `constant FilmGrainUniforms& u [[buffer(0)]]`.
struct FilmGrainUniforms {
    var density: Float
    var grainSize: Float
    var roughness: Float
    var chromaticity: Float
}
