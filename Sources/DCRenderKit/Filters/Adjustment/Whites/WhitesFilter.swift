//
//  WhitesFilter.swift
//  DCRenderKit
//
//  Whites adjustment via Filmic shoulder — the mirror of BlacksFilter's
//  Reinhard toe. Session C replaced the prior LUT-driven weighted-parabola
//  + luma-ratio fit with a principled operator; see the model-form
//  justification below.
//

import Foundation

/// Whites adjustment targeting highlight-region response via a Filmic
/// shoulder (inverse Reinhard toe applied to `1 − x`).
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Algorithm: **Filmic shoulder** — algebraic mirror of Reinhard toe.
///   Applying the Reinhard-with-scale toe to `1 − x` and folding the
///   complement back:
///
///         y = ε · x / ((1 − x) + ε · x)
///         ε = exp2(whites_norm · 1.0)    // whites_norm = slider / 100
///
///   - `ε = 1` at slider 0 ⇒ `y = x / (1 − x + x) = x` (identity).
///   - Slider `+1` ⇒ `ε = 2` ⇒ highlights lift
///     (`y(0.9) = 1.8 / 1.9 ≈ 0.947`; `y(0.5) = 1.0 / 1.5 ≈ 0.667`).
///   - Slider `−1` ⇒ `ε = 0.5` ⇒ highlights crush
///     (`y(0.9) = 0.45 / 0.55 ≈ 0.818`).
///   - Reference: same Reinhard toe / Filmic-toe primitive as
///     ``BlacksFilter``, mirrored via the Filmic shoulder construction
///     (John Hable's Filmic curve uses a toe/shoulder pair built from
///     this same algebraic form — *Uncharted 2 HDR Lighting*,
///     SIGGRAPH 2010; Blender AgX likewise pairs toe + shoulder).
/// - Why **not** the prior LUT-driven fitted form: the old weighted
///   parabola (positive) + luma-ratio (negative) with per-scene
///   LUT-interpolated `k100`, `b` was a 3-anchor polynomial fit,
///   parameter-heavy and with no closed-form backing. The shoulder
///   primitive is closed-form, single-parameter (`ε`), and symmetric
///   with the Blacks toe — the pair now forms a coherent filmic
///   curve the way professional grading tools expose it.
///
/// ## API change from the prior implementation
///
/// The `lumaMean` parameter is **removed** — the shoulder operator
/// doesn't need a scene-adaptive pivot (it concentrates effect at
/// `x → 1` by construction, regardless of scene mean). This is a
/// Session-C breaking change that downstream consumers need to adapt
/// to (drop the `lumaMean:` argument in `WhitesFilter.init`).
///
/// ## Parameter range
///
/// `whites` is `-100 ... +100`. Identity at 0. Shader clamps internally.
///
/// Symmetric with Blacks:
///   - Blacks ε = `exp2(−blacks · 1.0)`, Whites ε = `exp2(+whites · 1.0)`.
///   - `+100` on either slider halves the respective `(1−x)` / `x`
///     factor in the denominator; `−100` doubles it.
@available(iOS 18.0, *)
public struct WhitesFilter: FilterProtocol {

    /// Whites slider. Range `-100 ... +100`.
    public var whites: Float

    /// Color space the input texture is in. Drives the shader's
    /// linearize/delinearize wrapping. Shoulder math is applied in
    /// gamma space regardless of pipeline mode — matches the
    /// "photographer's intuition that Whites acts on perceived
    /// highlight brightness" framing used by consumer-grading tools.
    public var colorSpace: DCRColorSpace

    /// Create a ``WhitesFilter`` with the given slider value and the
    /// pipeline's current color-space mode.
    public init(
        whites: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.whites = whites
        self.colorSpace = colorSpace
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRWhitesFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(WhitesUniforms(
            whites: whites / 100.0,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRWhitesBody` lands in `WhitesFilter.metal` in Phase 3.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRWhitesBody",
            uniformStructName: "WhitesUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceText: BundledShaderSources.whitesFilter,
            sourceLabel: "WhitesFilter.metal"
        )
    }
}

/// Memory layout matches `constant WhitesUniforms& u [[buffer(0)]]`.
struct WhitesUniforms {
    /// `-1.0 ... +1.0`. Shader dead-zones around 0 for exact identity.
    var whites: Float
    /// 1 = linear input; 0 = gamma-encoded.
    var isLinearSpace: UInt32
}
