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
@available(iOS 18.0, *)
public struct SharpenFilter: FilterProtocol {

    /// Sharpen amount slider, `0 ... 100`.
    public var amount: Float

    /// Laplacian sampling step in **pixels of the current texture**. For a
    /// visually consistent effect across capture / editing / export, pass
    /// `round(1.0 * pixelsPerPoint)`. Minimum effective value is 1.
    public var step: Float

    /// Create a ``SharpenFilter`` with the given amount slider and
    /// `pixelsPerPoint`-scaled Laplacian sampling step.
    public init(amount: Float = 0, step: Float = 3.0) {
        self.amount = amount
        self.step = step
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRSharpenFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        // Product-side compression: raw amount/100 is too strong; ×1.6
        // peaks at +100 maps to a hand-tuned "strong but not haloed" level.
        //
        // FIXME(§8.6 Tier 2 archived): The × 1.6 factor is an empirical
        // hand-tuned constant reflecting human preference, not a
        // principled derivation. Note: CCDFilter's × 0.96 derivation
        // ("60 % of SharpenFilter amplitude") transitively depends on
        // this value; changing here requires the matching CCDFilter
        // update.
        FilterUniforms(SharpenUniforms(
            amount: (amount / 100.0) * 1.6,
            step: step
        ))
    }

    /// Declared fuse group (`nil` — Sharpen is not fusable).
    /// See ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { nil }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRSharpenBody` lands in `SharpenFilter.metal` in Phase 3.
    ///
    /// `radius = 8` is the neighbour-sample upper bound the Laplacian
    /// unsharp mask ever uses: the shader samples `±step` pixels on
    /// each axis, and `step = SharpenUniforms.step` is driven by
    /// `pixelsPerPoint × 1.0pt`. At a 3× iPhone screen step ≈ 3;
    /// preview contexts with heavier zoom can reach ~8; the bound is
    /// an inclusive conservative ceiling used by the compiler for
    /// tile-boundary analysis (TBDR backend, Phase 7) and does not
    /// change shader behaviour.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRSharpenBody",
            uniformStructName: "SharpenUniforms",
            kind: .neighborRead(radius: 8),
            wantsLinearInput: false,
            sourceMetalFile: FusionBodyDescriptor.bundledSDKMetalURL("SharpenFilter")
        )
    }
}

/// Memory layout matches `constant SharpenUniforms& u [[buffer(0)]]`.
struct SharpenUniforms {
    /// Effective sharpen strength `0 ... 2`. Shader clamps.
    var amount: Float
    /// Sampling step in pixels. Shader rounds to int and enforces ≥ 1.
    var step: Float
}
