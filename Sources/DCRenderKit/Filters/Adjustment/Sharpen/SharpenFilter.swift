//
//  SharpenFilter.swift
//  DCRenderKit
//
//  Laplacian unsharp-mask sharpen. Ported from DigiCam.
//

import Foundation

/// Laplacian unsharp-mask sharpening with `pixelsPerPoint`-aware sampling.
///
/// ## Model form justification
///
/// - Type: 2D neighborhood (4-neighbor Laplacian)
/// - Algorithm: unsharp mask — `center * (1 + 4·s) - sum(neighbors) * s`
///   - Reference: Gonzalez & Woods, *Digital Image Processing* §3.6.2
///     ("Using Second-Order Derivatives for Enhancement"). Same formulation
///     used across Adobe Camera Raw, darktable, Lightroom.
///   - Alternatives considered: bilateral-preserving sharpen (over-blurs
///     flat regions before enhancing edges, expensive), CAS / Contrast
///     Adaptive Sharpening (AMD FidelityFX — better at preserving smooth
///     gradients but more complex; revisit in Phase 2).
///
/// ## Spatial parameter (rules/spatial-params.md §1)
///
/// `step` is a visual-texture parameter. The Laplacian footprint must look
/// identical in pt on screen across capture preview (3× scale), editing
/// preview (proxy at view pt), and export (full resolution). Consumers
/// inject `step = round(1.0pt * pixelsPerPoint)` where `pixelsPerPoint`
/// is the display-context multiplier from `rules/spatial-params.md`.
///
/// Identity at `amount = 0` is exact (dead-zone short-circuit).
public struct SharpenFilter: FilterProtocol {

    /// Sharpen amount slider, `0 ... 100`.
    public var amount: Float

    /// Laplacian sampling step in **pixels of the current texture**. For a
    /// visually consistent effect across capture / editing / export, pass
    /// `round(1.0 * pixelsPerPoint)`. Minimum effective value is 1.
    public var step: Float

    public init(amount: Float = 0, step: Float = 3.0) {
        self.amount = amount
        self.step = step
    }

    public var modifier: ModifierEnum {
        .compute(kernel: "DCRSharpenFilter")
    }

    public var uniforms: FilterUniforms {
        // Product-side compression: raw amount/100 is too strong; ×1.6
        // peaks at +100 maps to a hand-tuned "strong but not haloed" level.
        FilterUniforms(SharpenUniforms(
            amount: (amount / 100.0) * 1.6,
            step: step
        ))
    }

    public static var fuseGroup: FuseGroup? { nil }
}

/// Memory layout matches `constant SharpenUniforms& u [[buffer(0)]]`.
struct SharpenUniforms {
    /// Effective sharpen strength `0 ... 2`. Shader clamps.
    var amount: Float
    /// Sampling step in pixels. Shader rounds to int and enforces ≥ 1.
    var step: Float
}
