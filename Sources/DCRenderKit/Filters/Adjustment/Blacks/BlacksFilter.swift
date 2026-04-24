//
//  BlacksFilter.swift
//  DCRenderKit
//
//  Blacks adjustment — per-channel `model_ka`. Ported from DigiCam.
//

import Foundation

/// Blacks adjustment via a Filmic-toe / Reinhard-toe-with-scale
/// operator.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel (tone adjustment)
/// - Algorithm: **Reinhard toe with scale** (a.k.a. Filmic toe):
///
///         y = x / (x + ε · (1 − x))
///         ε = exp2(−blacks_norm · 1.0)    // blacks_norm = slider / 100
///
///   - `ε = 1` at slider 0 ⇒ `y = x / (x + 1 − x) = x` (identity).
///   - Slider `+1` ⇒ `ε = 0.5` ⇒ shadows lift: `y(0.1) = 0.1 /
///     (0.1 + 0.5·0.9) = 0.182`. Low-`x` region lifted; `x → 1`
///     asymptotes to 1, so highlights are virtually unaffected.
///   - Slider `−1` ⇒ `ε = 2.0` ⇒ shadows crush: `y(0.1) = 0.053`.
///   - References: Reinhard et al., *Photographic Tone Reproduction*,
///     SIGGRAPH 2002 (the toe segment `C / (1 + C)` of Reinhard's
///     global operator, generalised here with a scale parameter
///     `ε` on the `(1 − x)` term). Same toe shape is used by
///     Blender AgX (post-Filmic) and Hable Filmic
///     (see "John Hable: Uncharted 2 HDR Lighting" 2010
///     presentation, section on toe/shoulder design).
/// - Why **not** the prior `y = x · (1 + k · (1 − x)^a)` with fitted
///   `k`, `a`: the old form was a polynomial envelope chosen via
///   MSE bakeoff against consumer-app exports (MSE 0.63 vs 3 other
///   candidates). No photo-grading primitive underwrote the exact
///   `(1 − x)^a` shape. Reinhard toe is the standard industry
///   primitive for shadow lift / crush and reduces the parameter
///   count from 2 fitted (`k`, `a`) to 1 interpretable (`ε`).
/// - Why `exp2` on the slider: maps slider `±1` to geometric
///   symmetry `ε ∈ {1/2, 2}`, matching the photographer's intuition
///   that "Blacks +100" and "Blacks −100" should be dimensionally
///   symmetric mirror operations.
///
/// ## Parameter range
///
/// `blacks` is `-100 ... +100`. Identity at 0. Extreme +100 / −100
/// halves / doubles `ε` — a comfortable slider end-point for
/// consumer grading tools (stronger than Lightroom-default Blacks,
/// gentler than "crush to black" as the prior negative branch did).
///
/// ## Breaking change from pre-Session-C fitted form
///
/// Identity still passes through exactly. Midtones and highlights
/// drift by less than 1 % (the toe asymptotes above ~0.7). Shadows
/// behave noticeably differently: the old negative branch crushed
/// to zero clamp at `−100`, while Reinhard toe crushes softly
/// (asymptotically, never reaching zero). Preset retuning needed
/// for shadow-heavy content at extreme slider positions —
/// intentional per Tier 2 "replace fitted curves with principled
/// operators".
@available(iOS 18.0, *)
public struct BlacksFilter: FilterProtocol {

    /// Blacks slider. Range `-100 ... +100`.
    public var blacks: Float

    /// Color space the input texture is in. Drives the shader's
    /// linearize/delinearize wrapping so the fit (done in gamma space)
    /// hits the same tonal location in linear mode.
    public var colorSpace: DCRColorSpace

    /// Create a ``BlacksFilter`` configured with a slider value and
    /// the pipeline's current color-space mode.
    public init(
        blacks: Float = 0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.blacks = blacks
        self.colorSpace = colorSpace
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRBlacksFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(BlacksUniforms(
            blacks: blacks / 100.0,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// Declared fuse group (`.toneAdjustment`). See
    /// ``FilterProtocol/fuseGroup``.
    public static var fuseGroup: FuseGroup? { .toneAdjustment }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4. The body function
    /// `DCRBlacksBody` lands in `BlacksFilter.metal` in Phase 3.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRBlacksBody",
            uniformStructName: "BlacksUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceText: BundledShaderSources.blacksFilter,
            sourceLabel: "BlacksFilter.metal"
        )
    }
}

/// Memory layout matches `constant BlacksUniforms& u [[buffer(0)]]`.
struct BlacksUniforms {
    /// `-1.0 ... +1.0`.
    var blacks: Float
    /// 1 = linear input; 0 = gamma-encoded.
    var isLinearSpace: UInt32
}
