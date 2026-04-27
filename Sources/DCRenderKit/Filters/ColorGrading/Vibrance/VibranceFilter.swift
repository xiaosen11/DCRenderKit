//
//  VibranceFilter.swift
//  DCRenderKit
//
//  Adobe-semantic Vibrance (OKLCh selective saturation + skin hue
//  protect). See `docs/contracts/vibrance.md` for the contract;
//  `Shaders/ColorGrading/Vibrance/VibranceFilter.metal` for the
//  kernel.
//

import Foundation

/// "Vibrance" — perceptually-selective saturation that boosts
/// low-chroma pixels more strongly than already-saturated ones AND
/// leaves warm skin hues largely untouched.
///
/// ## Model form justification
///
/// - Type: 1D per-pixel, perception-based (Tier 3)
/// - Algorithm: linear sRGB → OKLab → OKLCh; two multiplicative
///   weights modulate the slider's effect on chroma; gamut clamp at
///   constant `(L, h)`; OKLab → linear sRGB.
///   - Reference: Ottosson (2020), *A perceptual color space for image
///     processing*. https://bottosson.github.io/posts/oklab/
///   - Adobe/Lightroom "Vibrance" semantics (selective + skin protect)
///     codified from published behavioural descriptions (SLR Lounge,
///     Boris FX, Digital Photography School). The Adobe algorithm is
///     proprietary; our shader is an independent OKLCh implementation
///     that targets the same contract (`docs/contracts/vibrance.md`).
///   - Skin-hue parameters: centre ≈ 45° and half-width ≈ 25° on the
///     OKLCh hue axis, measured empirically from ColorChecker Light /
///     Dark Skin patches (h ≈ 44.9° and 46.7°) and cross-checked
///     against the CIELAB cross-cultural preferred-skin-hue of ≈ 49°
///     (IS&T 2020).
///
/// ## Weights
///
/// ```
/// w_lowsat = 1 − smoothstep(0.08, 0.25, C)   // low-chroma full weight
/// w_skin   = 1 − skin_hue_gate(h)             // skin hue: suppressed
/// C' = C · (1 + vibrance · w_lowsat · w_skin)
/// ```
///
/// Constants (`C_low`, `C_high`, skin centre / half-width) are internal
/// to the shader. They are calibrated against the `docs/contracts/vibrance.md`
/// conditions and the behaviour expected by the Vibrance name in
/// commercial photo tools; deviating from them changes filter character
/// and should only be done alongside a contract revision.
///
/// ## Parameter range
///
/// `vibrance` in `[-1, +1]`:
/// - `0` = identity (exact, up to Float16 quantization)
/// - Positive = selective saturation boost (low-C gets more, skin
///   protected)
/// - Negative = selective desaturation (low-C pulled toward grey,
///   high-C and skin largely unchanged)
///
/// ## Breaking change from pre-Session-C implementation
///
/// The prior implementation `mix(rgb, vec3(max), (max − mean) · −3·vib)`
/// (a GPUImage-family max-anchor saturation) behaved as a non-Adobe
/// "all pixels scale toward their max channel" operator — already-
/// saturated pixels received *more* boost rather than less, and no
/// skin protection existed. The current implementation implements the
/// Adobe Vibrance semantics (selective low-chroma boost + warm-skin-
/// hue protection). Slider handfeel and visual response differ
/// noticeably; existing presets that depend on the old curve will
/// need retuning. See CHANGELOG.md `[Unreleased]` for migration notes.
@available(iOS 18.0, *)
public struct VibranceFilter: FilterProtocol {

    /// Vibrance slider. Range `-1 ... +1`; identity at `0`. Positive
    /// selectively boosts low-chroma pixels (protecting already-saturated
    /// colours and warm skin hues); negative selectively desaturates
    /// low-chroma pixels.
    public var vibrance: Float

    /// Color space the input texture is encoded in. See
    /// ``SaturationFilter/colorSpace`` for the same rationale —
    /// OKLab math is calibrated for linear sRGB, so the shader
    /// linearises perceptually-encoded input before the OKLab
    /// round-trip and re-encodes on output.
    public var colorSpace: DCRColorSpace

    /// Create a ``VibranceFilter`` with the given slider and the
    /// pipeline's current color-space mode.
    public init(
        vibrance: Float = 0.0,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.vibrance = vibrance
        self.colorSpace = colorSpace
    }

    /// Compute-kernel binding. See ``FilterProtocol/modifier``.
    public var modifier: ModifierEnum {
        .compute(kernel: "DCRVibranceFilter")
    }

    /// Typed uniform payload. See ``FilterProtocol/uniforms``.
    public var uniforms: FilterUniforms {
        FilterUniforms(VibranceUniforms(
            vibrance: vibrance,
            isLinearSpace: colorSpace == .linear ? 1 : 0
        ))
    }

    /// Fusion metadata. See ``FilterProtocol/fusionBody`` and
    /// `docs/pipeline-compiler-design.md` §4.
    ///
    /// `wantsLinearInput = false` mirrors the Exposure / Contrast /
    /// Saturation pattern — the body internally branches on
    /// `isLinearSpace` and self-converts in perceptual mode, so
    /// VerticalFusion can cluster Vibrance with the other tone
    /// operators uniformly.
    public var fusionBody: FusionBodyDescriptor {
        FusionBodyDescriptor(
            functionName: "DCRVibranceBody",
            uniformStructName: "VibranceUniforms",
            kind: .pixelLocal,
            wantsLinearInput: false,
            sourceText: BundledShaderSources.vibranceFilter,
            sourceLabel: "VibranceFilter.metal"
        )
    }
}

/// Memory layout matches `constant VibranceUniforms& u [[buffer(0)]]`.
struct VibranceUniforms {
    /// `-1 ... +1`, identity at `0`. Shader clamps.
    var vibrance: Float
    /// 1 = linear input; 0 = perceptually-gamma-encoded.
    var isLinearSpace: UInt32
}
