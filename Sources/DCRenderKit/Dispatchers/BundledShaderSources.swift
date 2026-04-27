//
//  BundledShaderSources.swift
//  DCRenderKit
//
//  Verbatim source text of every built-in pixel-local / neighbour-
//  read filter's `.metal` file. The compiler's runtime codegen
//  reads these strings directly instead of hitting Bundle.module —
//  Xcode's SPM integration for iOS does not copy `.metal` sources
//  into the app's resource bundle (it only compiles them into the
//  default metallib), so a Bundle-based runtime read worked under
//  `swift test` on macOS but crashed at launch on an iPhone. Baking
//  the sources into Swift constants makes the compiler path work
//  identically on every platform and removes runtime file-I/O from
//  the hot path entirely.
//
//  Regenerating: run `Scripts/generate-bundled-shaders.sh`. Edit a
//  `.metal` file under `Sources/DCRenderKit/Shaders/` → re-run the
//  script → commit the regenerated file alongside the `.metal`
//  change. Check script for list of bundled filters; extend if new
//  fusion-body filter is added.
//

import Foundation

/// Canonical source text of every SDK-built-in filter's `.metal`
/// file. Consumed by `ShaderSourceExtractor` via
/// `FusionBody.sourceText`.
@available(iOS 18.0, *)
internal enum BundledShaderSources {

    /// Verbatim text of `ExposureFilter.metal`.
    static let exposureFilter: String = #"""
//
//  ExposureFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── ExposureFilter — symmetric linear gain with Reinhard rolloff ──
//
// gain = exp2(exposure · 0.7 · EV_RANGE),  EV_RANGE = 4.25
//
// Positive (exposure > 0, gain > 1):
//   Extended Reinhard tonemap prevents highlight overshoot.
//   Reference: Reinhard et al., SIGGRAPH 2002
//   "Photographic Tone Reproduction". Whitepoint w = 0.95·gain.
//   mapped = x·gain · (1 + x·gain / w²) / (1 + x·gain)
//
// Negative (exposure < 0, gain < 1):
//   Pure linear gain y = clamp(x · gain, 0, 1).
//   gain < 1 ⇒ x·gain ≤ gain ≤ 1: no overshoot to protect against,
//   so no tone-mapper is warranted. This is the physically exact
//   "less light reaches the sensor" operation. The prior
//   `A·x^γ + B·x` fitted curve was polynomial shaping bolted on
//   the same primitive; replaced with the linear form.
//
// Identity at exposure = 0 (both branches gated by dead-zone).
//
// ## Color-space branching
//
// Both branches are defined in linear-light. How the shader gets
// there depends on SDK configuration:
//
//   u.isLinearSpace == 0 (perceptual mode):
//     Input texture stores sRGB-gamma encoded floats. Shader
//     linearizes with the canonical IEC 61966-2-1 piecewise helper
//     (MIRROR of Foundation/SRGBGamma.metal), applies the branch,
//     then re-encodes. Output stays gamma-encoded.
//
//   u.isLinearSpace == 1 (linear mode):
//     Input texture is already linear; the branches run directly.
//     Output stays linear (drawable bgra8Unorm_srgb handles encoding).

struct ExposureUniforms {
    float exposure;       // -1.0 ... +1.0
    uint  isLinearSpace;  // 1 if the input is linear-light; 0 if gamma-encoded.
};

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/SRGBGamma.metal. Edit one copy → edit every
// mirror. Grep:
//
//     // MIRROR: Foundation/SRGBGamma.metal

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}

inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// @dcr:body-begin DCRExposureBody
inline half3 DCRExposureBody(half3 rgbIn, constant ExposureUniforms& u) {
    half3 color = rgbIn;

    // Product compression: slider ±1 maps to 70% of raw fit magnitude.
    const float exposure = clamp(u.exposure, -1.0f, 1.0f) * 0.7f;
    const bool isLinear = (u.isLinearSpace != 0u);

    if (exposure > 0.001f) {
        // Positive: Extended Reinhard in linear-light space.
        // FIXME(§8.6 Tier 2 archived): EV_RANGE = 4.25 maps slider ±1
        // to ±4.25 EV — slightly narrower than Lightroom's ±5 EV
        // standard. Hand-chosen for "commercial slider feel", not a
        // derived number.
        //
        // `white * 0.95` is the Extended Reinhard white-point offset —
        // keeps the mapped max slightly below pure gain to avoid
        // numerical saturation at the peak. The 0.95 is an empirical
        // safety margin, not a principled derivation.
        const float EV_RANGE = 4.25f;
        const float gain = pow(2.0f, exposure * EV_RANGE);
        const float white = gain * 0.95f;
        const float white2 = white * white;

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float linear = isLinear ? max(c, 0.0f)
                                    : DCRSRGBGammaToLinear(c);
            float gained = linear * gain;
            float mapped = gained * (1.0f + gained / white2) / (1.0f + gained);
            float clamped = clamp(mapped, 0.0f, 1.0f);
            color[ch] = half(isLinear ? clamped
                                      : DCRSRGBLinearToGamma(clamped));
        }
    } else if (exposure < -0.001f) {
        // Negative: pure linear gain in linear-light space.
        // gain < 1 ⇒ x·gain ∈ [0, gain) ⊂ [0, 1): no overshoot to
        // protect against, so no tone-mapper needed. "Less light
        // reaches the sensor" in physical terms.
        const float EV_RANGE = 4.25f;
        const float gain = pow(2.0f, exposure * EV_RANGE);

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float linear = isLinear ? max(c, 0.0f)
                                    : DCRSRGBGammaToLinear(c);
            float gained = linear * gain;
            float clamped = clamp(gained, 0.0f, 1.0f);
            color[ch] = half(isLinear ? clamped
                                      : DCRSRGBLinearToGamma(clamped));
        }
    }

    return color;
}
// @dcr:body-end

// The `DCRExposureFilter` kernel previously shipped here was
// retired in Phase 5 step 5.5 of the pipeline-compiler refactor.
// Every dispatch — including single-filter — now flows through the
// runtime-compiled uber kernel produced by `MetalSourceBuilder`
// from the body function above. See
// `docs/pipeline-compiler-design.md` §4 for the body-function-only
// shader convention and `Tests/DCRenderKitTests/LegacyKernels/`
// for the frozen pre-refactor copy kept as a Phase 7 parity gate.
"""#

    /// Verbatim text of `ContrastFilter.metal`.
    static let contrastFilter: String = #"""
//
//  ContrastFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── ContrastFilter — DaVinci log-space slope around scene pivot ──
//
// Model: y = pivot · (x / pivot)^slope,  slope = exp2(contrast · 1.585)
//   Per-channel in gamma (display) space, clamped to [0, 1].
//   pivot = image mean luminance (scene-adaptive), clamped to
//           [0.05, 0.95] for numerical stability.
//
// Reference: DaVinci Resolve primary-contrast operator. See
//   https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/
//   §"slope/offset/power" — the same slope/pivot form appears in the
//   ACES RRT middle linear segment and in OCIO primary-grading docs.
// The 1.585 = log2(3) magic number makes slider = ±1 yield
//   slope ∈ {1/3, 3} — the commercial "±1.585 stops of contrast"
//   convention.
//
// Identity at contrast = 0: slope = 2^0 = 1, y = pivot·(x/pivot)^1 = x.
//
// ## Color-space branching
//
// u.isLinearSpace == 0: apply the slope curve directly on gamma-encoded
//   floats. This is the curve's native domain.
// u.isLinearSpace == 1: input is linear-light. Un-linearize to gamma
//   with the shared IEC 61966-2-1 helpers → apply the slope → re-
//   linearize. The pivot is also converted to gamma space so it anchors
//   at the same perceived-brightness point regardless of space.

struct ContrastUniforms {
    float contrast;       // -1.0 ... +1.0
    float lumaMean;       //  0   ...  1
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/SRGBGamma.metal. Edit one copy → edit every
// mirror. Grep:
//
//     // MIRROR: Foundation/SRGBGamma.metal

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// @dcr:body-begin DCRContrastBody
inline half3 DCRContrastBody(half3 rgbIn, constant ContrastUniforms& u) {
    half3 color = rgbIn;

    const float contrast = clamp(u.contrast, -1.0f, 1.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    // lumaMean is fed in the pipeline's current space. Convert to
    // gamma-space so the pivot anchors at the same perceived-
    // brightness location regardless of whether the pipeline carries
    // linear or gamma values.
    float pivot = u.lumaMean;
    if (isLinear) {
        pivot = DCRSRGBLinearToGamma(pivot);
    }
    pivot = clamp(pivot, 0.05f, 0.95f);

    // log2(3) ≈ 1.585 → slider ±1 maps to slope ∈ {1/3, 3}, the
    // commercial "±1.585 stops of contrast" convention.
    const float slope = exp2(contrast * 1.585f);

    for (int ch = 0; ch < 3; ch++) {
        float x = float(color[ch]);
        float x_gamma = isLinear ? DCRSRGBLinearToGamma(x) : x;
        // pow(x/pivot, slope) — pivot-anchored log-space slope.
        // max(..., 1e-6) guards pow against a zero base at slope < 1
        // (which would otherwise emit 0^negative = inf).
        float ratio = max(x_gamma, 1e-6f) / pivot;
        float y = pivot * pow(ratio, slope);
        float y_clamped = clamp(y, 0.0f, 1.0f);
        color[ch] = half(isLinear ? DCRSRGBGammaToLinear(y_clamped) : y_clamped);
    }

    return color;
}
// @dcr:body-end

// Standalone `DCRContrastFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `BlacksFilter.metal`.
    static let blacksFilter: String = #"""
//
//  BlacksFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── BlacksFilter — Reinhard toe with scale (Filmic toe) ──
//
// Model: y = x / (x + ε · (1 − x)),  ε = exp2(−slider · 1.0)
//   ε = 1 at slider = 0 ⇒ identity.
//   ε < 1 (slider > 0) ⇒ shadows lift (y(0.1) = 0.182 at ε=0.5).
//   ε > 1 (slider < 0) ⇒ shadows crush (y(0.1) = 0.053 at ε=2).
// Reference: Reinhard et al. *Photographic Tone Reproduction* (SIGGRAPH
// 2002), toe segment `C/(1+C)` generalised with an ε scale on the
// (1-x) term. Same form used by Blender AgX toe and Hable Filmic toe.
//
// ## Color-space branching (u.isLinearSpace)
//
//   0 → gamma input, apply curve directly.
//   1 → linear input; un-linearize to gamma → apply toe → re-linearize.
//   The toe is conceptually shape-agnostic so applying in either space
//   is valid, but gamma-space application matches the photographer's
//   intuition of "Blacks acts on perceived shadow brightness".
//
// Identity at blacks = 0 is exact: ε = 2^0 = 1 ⇒ y = x.

struct BlacksUniforms {
    float blacks;         // -1.0 ... +1.0
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/SRGBGamma.metal. Edit one copy → edit every
// mirror. Grep:
//
//     // MIRROR: Foundation/SRGBGamma.metal

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// @dcr:body-begin DCRBlacksBody
inline half3 DCRBlacksBody(half3 rgbIn, constant BlacksUniforms& u) {
    half3 color = rgbIn;

    const float blacks = clamp(u.blacks, -1.0f, 1.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    if (abs(blacks) <= 0.001f) {
        return color;
    }

    // Reinhard toe scale. slider = 0 ⇒ ε = 1 ⇒ identity.
    // slider > 0 ⇒ ε < 1 ⇒ shadow lift; slider < 0 ⇒ ε > 1 ⇒ shadow crush.
    const float eps = exp2(-blacks * 1.0f);

    for (int ch = 0; ch < 3; ch++) {
        float c = float(color[ch]);
        float c_gamma = isLinear ? DCRSRGBLinearToGamma(c) : c;
        // Reinhard toe with scale: y = x / (x + ε · (1 − x)).
        // Denominator is strictly positive for x ∈ [0, 1] and ε > 0
        // (ε = exp2(±1) ∈ [0.5, 2] here), so no guard is needed —
        // but we clamp y to [0, 1] anyway against Float16 rounding
        // nudging the asymptote one ULP past 1.
        float denom = c_gamma + eps * (1.0f - c_gamma);
        float y = c_gamma / max(denom, 1e-6f);
        float y_clamped = clamp(y, 0.0f, 1.0f);
        color[ch] = half(isLinear ? DCRSRGBGammaToLinear(y_clamped) : y_clamped);
    }

    return color;
}
// @dcr:body-end

// Standalone `DCRBlacksFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `WhitesFilter.metal`.
    static let whitesFilter: String = #"""
//
//  WhitesFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── WhitesFilter — Filmic shoulder (inverse Reinhard toe) ──
//
// Model: y = ε · x / ((1 − x) + ε · x),  ε = exp2(slider · 1.0)
//   ε = 1 at slider = 0 ⇒ identity.
//   ε > 1 (slider > 0) ⇒ highlights lift (y(0.9) = 0.947 at ε=2).
//   ε < 1 (slider < 0) ⇒ highlights crush (y(0.9) = 0.818 at ε=0.5).
//
// Reference: same Reinhard-toe-with-scale primitive as BlacksFilter,
// reflected through `x ↔ 1−x` to target the shoulder instead of the toe.
// Professional filmic curves (Hable Filmic, Blender AgX) pair toe +
// shoulder built on exactly this algebraic form.
//
// ## Color-space branching (u.isLinearSpace)
//
//   0 → gamma input, apply shoulder directly.
//   1 → linear input; un-linearize → apply shoulder → re-linearize.
//   Shoulder anchors to "perceived highlight brightness" so gamma-
//   space application matches photographer intuition regardless of
//   pipeline numeric domain.
//
// Identity at whites = 0 is exact: ε = 2^0 = 1 ⇒ denom = 1 ⇒ y = x.

struct WhitesUniforms {
    float whites;         // -1.0 ... +1.0
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/SRGBGamma.metal. Edit one copy → edit every
// mirror. Grep:
//
//     // MIRROR: Foundation/SRGBGamma.metal

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}

inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// @dcr:body-begin DCRWhitesBody
inline half3 DCRWhitesBody(half3 rgbIn, constant WhitesUniforms& u) {
    half3 color = rgbIn;

    const float whites = clamp(u.whites, -1.0f, 1.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    if (abs(whites) <= 0.001f) {
        return color;
    }

    // Filmic shoulder scale. slider = 0 ⇒ ε = 1 ⇒ identity.
    // slider > 0 ⇒ ε > 1 ⇒ highlight lift; slider < 0 ⇒ ε < 1 ⇒ crush.
    const float eps = exp2(whites * 1.0f);

    for (int ch = 0; ch < 3; ch++) {
        float c = float(color[ch]);
        float c_gamma = isLinear ? DCRSRGBLinearToGamma(c) : c;
        // Filmic shoulder: y = ε·x / ((1 − x) + ε·x).
        // Denominator strictly positive on [0, 1] for ε ∈ [0.5, 2]
        // (guaranteed by exp2 on clamped slider).
        float denom = (1.0f - c_gamma) + eps * c_gamma;
        float y = (eps * c_gamma) / max(denom, 1e-6f);
        float y_clamped = clamp(y, 0.0f, 1.0f);
        color[ch] = half(isLinear ? DCRSRGBGammaToLinear(y_clamped) : y_clamped);
    }

    return color;
}
// @dcr:body-end

// Standalone `DCRWhitesFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `SharpenFilter.metal`.
    static let sharpenFilter: String = #"""
//
//  SharpenFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// 4-neighbor Laplacian unsharp mask:
//   sharpened = center * (1 + 4s) - (left + right + top + bottom) * s
// Output clamped to [0, 1] to prevent halo artifacts in overflow regions.
// Center-pixel alpha is used (not neighbor alpha — that would introduce
// edge-of-texture alpha bleed).

struct SharpenUniforms {
    float amount;   // 0 ... 2
    float step;     // sampling step in pixels
};

// Body templated on `Tap` so codegen can substitute either
// `DCRRawSourceTap` (default) or a `KernelInlining`-generated
// fused tap that pre-applies an upstream pixelLocal body to each
// sample. Tap.read(int2) handles bounds clamping internally.
//
// @dcr:body-begin DCRSharpenBody
template <typename Tap>
inline half3 DCRSharpenBody(
    half3 rgbIn,
    constant SharpenUniforms& u,
    uint2 gid,
    Tap src
) {
    const float amount = clamp(u.amount, 0.0f, 2.0f);
    const int step     = max(int(round(u.step)), 1);

    if (amount < 0.001f) {
        return rgbIn;
    }

    const int2 pos = int2(gid);
    half4 left  = src.read(pos + int2(-step,  0));
    half4 right = src.read(pos + int2( step,  0));
    half4 top   = src.read(pos + int2( 0, -step));
    half4 bot   = src.read(pos + int2( 0,  step));

    const half s = half(amount);
    const half centerMul = 1.0h + 4.0h * s;
    half3 sharpened = rgbIn * centerMul
        - (left.rgb + right.rgb + top.rgb + bot.rgb) * s;

    return clamp(sharpened, half3(0.0h), half3(1.0h));
}
// @dcr:body-end

// Standalone `DCRSharpenFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `SaturationFilter.metal`.
    static let saturationFilter: String = #"""
//
//  SaturationFilter.metal
//  DCRenderKit
//
//  OKLCh-based uniform chroma scaling. The kernel lifts linear sRGB to
//  OKLab (Ottosson 2020), multiplies the chroma component C by the
//  slider, clamps back into the sRGB gamut at constant L / h, then
//  lowers the result back to linear sRGB.
//
//  This is a rewrite of the Rec.709 luma-anchored mix that shipped
//  prior to #77. See `docs/contracts/saturation.md` for the measurable
//  contract; breaking-change notes live in the SaturationFilter doc
//  comment and in the commit message that introduced the rewrite.
//

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/OKLab.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. The canonical copy of these helpers
// lives in Foundation/OKLab.metal together with a test-only kernel
// suite. When you edit one copy, grep for
//
//     // MIRROR: Foundation/OKLab.metal
//
// and update every mirror. A future Phase 2 tech-debt item will
// replace the mirroring with a build-time Metal preprocessor.
//
// Reference: Ottosson (2020) — https://bottosson.github.io/posts/oklab/

static inline float3 DCRLinearSRGBToOKLab(float3 rgb) {
    const float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
    const float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
    const float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

    const float l_ = sign(l) * pow(abs(l), 1.0f / 3.0f);
    const float m_ = sign(m) * pow(abs(m), 1.0f / 3.0f);
    const float s_ = sign(s) * pow(abs(s), 1.0f / 3.0f);

    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
    );
}

static inline float3 DCROKLabToLinearSRGB(float3 lab) {
    const float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    const float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    const float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

    const float l = l_ * l_ * l_;
    const float m = m_ * m_ * m_;
    const float s = s_ * s_ * s_;

    return float3(
         4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

static inline float3 DCROKLabToOKLCh(float3 lab) {
    const float C = length(lab.yz);
    // `atan2(0, 0)` returns NaN on some Apple Metal GPU
    // implementations; substitute h = 0 at C ≈ 0 to keep
    // downstream OKLChToOKLab from producing NaN-poisoned output.
    // See canonical OKLab.metal for the full diagnosis; mirror.
    const float h = (C < (1.0f / 4096.0f)) ? 0.0f : atan2(lab.z, lab.y);
    return float3(lab.x, C, h);
}

static inline float3 DCROKLChToOKLab(float3 lch) {
    const float a = lch.y * cos(lch.z);
    const float b = lch.y * sin(lch.z);
    return float3(lch.x, a, b);
}

constant float kDCROKLabGamutMargin = 1.0f / 4096.0f;

static inline bool DCROKLabIsInGamut(float3 rgb) {
    return all(rgb >= -kDCROKLabGamutMargin)
        && all(rgb <= 1.0f + kDCROKLabGamutMargin);
}

static inline float3 DCROKLChGamutClamp(float3 lch) {
    const float3 rgb0 = DCROKLabToLinearSRGB(DCROKLChToOKLab(lch));
    if (DCROKLabIsInGamut(rgb0)) {
        return lch;
    }
    float C_lo = 0.0f;
    float C_hi = lch.y;
    for (int i = 0; i < 10; i++) {
        const float C_mid = 0.5f * (C_lo + C_hi);
        const float3 rgb = DCROKLabToLinearSRGB(DCROKLChToOKLab(float3(lch.x, C_mid, lch.z)));
        if (DCROKLabIsInGamut(rgb)) {
            C_lo = C_mid;
        } else {
            C_hi = C_mid;
        }
    }
    return float3(lch.x, C_lo, lch.z);
}

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// ═══════════════════════════════════════════════════════════════════
// Saturation kernel
// ═══════════════════════════════════════════════════════════════════

struct SaturationUniforms {
    float saturation;
    uint  isLinearSpace;
};

// @dcr:body-begin DCRSaturationBody
inline half3 DCRSaturationBody(half3 rgbIn, constant SaturationUniforms& u) {
    const float s = clamp(u.saturation, 0.0f, 2.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    // OKLab is defined for non-negative linear sRGB (Ottosson 2020).
    // Two-stage input normalisation:
    //   1. Clamp sub-gamut overshoot (`x < 0` → `0`) — handles
    //      WhiteBalance YIQ-tint extremes and any other upstream
    //      OOG.
    //   2. Linearise (perceptual mode only) — handles gamma-encoded
    //      `bgra8Unorm` source (the edit-preview JPEG/PNG path).
    // The gamma helper has its own `max(c, 0)`, so stage 1 is
    // redundant on the perceptual branch. Keeping it explicit makes
    // the sanitisation contract visible at the call site rather than
    // buried inside a helper's edge-case guard. HDR overshoot
    // (`> 1`) is preserved.
    const float3 rgbSanitised = max(float3(rgbIn), 0.0f);
    const float3 rgbLinear = isLinear
        ? rgbSanitised
        : float3(
            DCRSRGBGammaToLinear(rgbSanitised.x),
            DCRSRGBGammaToLinear(rgbSanitised.y),
            DCRSRGBGammaToLinear(rgbSanitised.z)
        );

    // linear sRGB → OKLCh
    const float3 lab = DCRLinearSRGBToOKLab(rgbLinear);
    float3 lch = DCROKLabToOKLCh(lab);

    // Uniform chroma scaling (Adobe-like saturation — no hue protect).
    lch.y *= s;

    // Keep (L, h) fixed; reduce C only as much as the gamut requires.
    lch = DCROKLChGamutClamp(lch);

    // OKLCh → linear sRGB
    const float3 lab_out = DCROKLChToOKLab(lch);
    const float3 rgbOut = DCROKLabToLinearSRGB(lab_out);

    if (isLinear) {
        return half3(rgbOut);
    }
    return half3(
        DCRSRGBLinearToGamma(rgbOut.x),
        DCRSRGBLinearToGamma(rgbOut.y),
        DCRSRGBLinearToGamma(rgbOut.z)
    );
}
// @dcr:body-end

// Standalone `DCRSaturationFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `VibranceFilter.metal`.
    static let vibranceFilter: String = #"""
//
//  VibranceFilter.metal
//  DCRenderKit
//
//  Adobe-semantic Vibrance: perceptually-selective chroma boost in
//  OKLCh that protects already-saturated pixels AND warm skin hues.
//  Replaces the GPUImage-lineage `(max - mean) × -3·vib` kernel that
//  shipped prior to #14.
//
//  Contract: docs/contracts/vibrance.md (§8.2 A+.4)
//  Space: OKLab (Ottosson 2020 — https://bottosson.github.io/posts/oklab/)
//

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/OKLab.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/OKLab.metal together with a test-only kernel
// suite. Edit one copy → edit every mirror. Grep:
//
//     // MIRROR: Foundation/OKLab.metal

static inline float3 DCRLinearSRGBToOKLab(float3 rgb) {
    const float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
    const float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
    const float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

    const float l_ = sign(l) * pow(abs(l), 1.0f / 3.0f);
    const float m_ = sign(m) * pow(abs(m), 1.0f / 3.0f);
    const float s_ = sign(s) * pow(abs(s), 1.0f / 3.0f);

    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
    );
}

static inline float3 DCROKLabToLinearSRGB(float3 lab) {
    const float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    const float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    const float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

    const float l = l_ * l_ * l_;
    const float m = m_ * m_ * m_;
    const float s = s_ * s_ * s_;

    return float3(
         4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

static inline float3 DCROKLabToOKLCh(float3 lab) {
    const float C = length(lab.yz);
    // `atan2(0, 0)` returns NaN on some Apple Metal GPU
    // implementations; substitute h = 0 at C ≈ 0 to keep
    // downstream OKLChToOKLab from producing NaN-poisoned output.
    // See canonical OKLab.metal for the full diagnosis; mirror.
    const float h = (C < (1.0f / 4096.0f)) ? 0.0f : atan2(lab.z, lab.y);
    return float3(lab.x, C, h);
}

static inline float3 DCROKLChToOKLab(float3 lch) {
    const float a = lch.y * cos(lch.z);
    const float b = lch.y * sin(lch.z);
    return float3(lch.x, a, b);
}

constant float kDCROKLabGamutMargin = 1.0f / 4096.0f;

static inline bool DCROKLabIsInGamut(float3 rgb) {
    return all(rgb >= -kDCROKLabGamutMargin)
        && all(rgb <= 1.0f + kDCROKLabGamutMargin);
}

static inline float3 DCROKLChGamutClamp(float3 lch) {
    const float3 rgb0 = DCROKLabToLinearSRGB(DCROKLChToOKLab(lch));
    if (DCROKLabIsInGamut(rgb0)) {
        return lch;
    }
    float C_lo = 0.0f;
    float C_hi = lch.y;
    for (int i = 0; i < 10; i++) {
        const float C_mid = 0.5f * (C_lo + C_hi);
        const float3 rgb = DCROKLabToLinearSRGB(DCROKLChToOKLab(float3(lch.x, C_mid, lch.z)));
        if (DCROKLabIsInGamut(rgb)) {
            C_lo = C_mid;
        } else {
            C_hi = C_mid;
        }
    }
    return float3(lch.x, C_lo, lch.z);
}

// ═══════════════════════════════════════════════════════════════════
// Vibrance-specific constants
// ═══════════════════════════════════════════════════════════════════
// Low-saturation boost curve (smoothstep from full-weight to zero):
// - C < C_LOW_BOOST:   w_lowsat = 1 (full boost)
// - C > C_HIGH_BOOST:  w_lowsat = 0 (no boost — already saturated)
//
// Range chosen against OKLCh C of sRGB primaries (C_red ≈ 0.26,
// C_green ≈ 0.30, C_blue ≈ 0.31, ColorChecker skin patches ≈ 0.05–0.08).
// C_LOW_BOOST = 0.08 catches near-grayscale mid-chroma pixels; C_HIGH
// = 0.25 puts saturated primaries in the no-boost band.
constant float kDCRVibranceCLow  = 0.08f;
constant float kDCRVibranceCHigh = 0.25f;

// Skin hue protection (rads, OKLCh hue axis):
// - Centre ≈ 0.785 rad ≈ 45° — empirically matches ColorChecker Light
//   Skin (h ≈ 44.9°) and Dark Skin (h ≈ 46.7°) OKLCh hue, and aligns
//   with the cross-cultural preferred skin hue ≈ 49° reported in
//   CIELAB (IS&T 2020, "Preferred skin reproduction centres").
// - Half-width 0.436 rad ≈ 25° — covers the observed CIELAB skin hue
//   range 25°–80° mapped approximately to OKLCh. Smoothstep band has
//   inner edge at 70 % of the half-width (0.306 rad ≈ 17.5°) and outer
//   edge at 130 % (0.567 rad ≈ 32.5°) for a softened gate.
constant float kDCRVibranceSkinHueCenter     = 0.785398163f;   // π/4
constant float kDCRVibranceSkinHueInnerEdge  = 0.305432619f;   // 70 % of 25°
constant float kDCRVibranceSkinHueOuterEdge  = 0.566502879f;   // 130 % of 25°

// ═══════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════

/// Signed angular difference wrapped into `[-π, π]`, then absolute value.
float DCRVibranceAbsAngularDiff(float h1, float h2) {
    float d = h1 - h2;
    if (d >  M_PI_F) d -= 2.0f * M_PI_F;
    if (d < -M_PI_F) d += 2.0f * M_PI_F;
    return abs(d);
}

/// Skin gate: 1 near skin hue, 0 away, smoothstep transition.
float DCRVibranceSkinHueGate(float h) {
    const float delta = DCRVibranceAbsAngularDiff(h, kDCRVibranceSkinHueCenter);
    return 1.0f - smoothstep(kDCRVibranceSkinHueInnerEdge, kDCRVibranceSkinHueOuterEdge, delta);
}

// ═══════════════════════════════════════════════════════════════════
// Vibrance kernel
// ═══════════════════════════════════════════════════════════════════

// MIRROR: Foundation/SRGBGamma.metal (perceptual-mode round-trip)
inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

struct VibranceUniforms {
    float vibrance;
    uint  isLinearSpace;
};

// @dcr:body-begin DCRVibranceBody
inline half3 DCRVibranceBody(half3 rgbIn, constant VibranceUniforms& u) {
    const float vib = clamp(u.vibrance, -1.0f, 1.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    // See SaturationFilter.metal for the full rationale. Two-stage
    // sanitisation: clamp sub-gamut overshoot to zero, then linearise
    // gamma-encoded input (perceptual mode) before OKLab round-trip.
    // HDR overshoot (`> 1`) is preserved.
    const float3 rgbSanitised = max(float3(rgbIn), 0.0f);
    const float3 rgbLinear = isLinear
        ? rgbSanitised
        : float3(
            DCRSRGBGammaToLinear(rgbSanitised.x),
            DCRSRGBGammaToLinear(rgbSanitised.y),
            DCRSRGBGammaToLinear(rgbSanitised.z)
        );

    // linear sRGB → OKLCh
    const float3 lab = DCRLinearSRGBToOKLab(rgbLinear);
    float3 lch = DCROKLabToOKLCh(lab);

    // Selective weights.
    const float w_lowsat = 1.0f - smoothstep(kDCRVibranceCLow, kDCRVibranceCHigh, lch.y);
    const float w_skin   = 1.0f - DCRVibranceSkinHueGate(lch.z);

    // Adobe-style selective boost: low-C + non-skin pixels see the
    // full slider effect; high-C or skin-hue pixels are protected.
    // Identity when vib = 0 (boost factor = 1).
    lch.y = lch.y * (1.0f + vib * w_lowsat * w_skin);

    // Preserve L and h; reduce C only if the boost pushed it past the
    // gamut boundary. Negative boosts (desaturation) never exceed the
    // boundary.
    lch = DCROKLChGamutClamp(lch);

    // OKLCh → linear sRGB
    const float3 lab_out = DCROKLChToOKLab(lch);
    const float3 rgbOut  = DCROKLabToLinearSRGB(lab_out);

    if (isLinear) {
        return half3(rgbOut);
    }
    return half3(
        DCRSRGBLinearToGamma(rgbOut.x),
        DCRSRGBLinearToGamma(rgbOut.y),
        DCRSRGBLinearToGamma(rgbOut.z)
    );
}
// @dcr:body-end

// Standalone `DCRVibranceFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `WhiteBalanceFilter.metal`.
    static let whiteBalanceFilter: String = #"""
//
//  WhiteBalanceFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

struct WhiteBalanceUniforms {
    float temperature;    // Kelvin, 4000 ... 8000
    float tint;           // -200 ... +200
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// HDR-safe Overlay blend: linear extrapolation outside [0, 1] instead
// of the standard piecewise formula's undefined behaviour.
inline half dcr_whiteBalanceOverlay(half v, half w) {
    if (v < 0.0h) {
        return v * (2.0h * w);
    } else if (v > 1.0h) {
        return 1.0h + 2.0h * (1.0h - w) * (v - 1.0h);
    } else if (v < 0.5h) {
        return 2.0h * v * w;
    } else {
        return 1.0h - 2.0h * (1.0h - v) * (1.0h - w);
    }
}

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/SRGBGamma.metal. Edit one copy → edit every
// mirror. Grep:
//
//     // MIRROR: Foundation/SRGBGamma.metal

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// ## Color-space branching
//
// The warm target (0.93, 0.54, 0) and tempCoef / tint fit were all done
// in gamma space against JPEG references from a consumer photo-editing
// app. YIQ is a linear transform of RGB, and its perceptual meaning
// depends on which space the RGB is in — mixing with the warm target in
// linear space produces visibly different whites-shift than in gamma
// space.
//
// u.isLinearSpace == 1: un-linearize to gamma → run the fit → re-linearize
// u.isLinearSpace == 0: direct gamma-space math (DigiCam parity)

// @dcr:body-begin DCRWhiteBalanceBody
inline half3 DCRWhiteBalanceBody(half3 rgbIn, constant WhiteBalanceUniforms& u) {
    const bool isLinear = (u.isLinearSpace != 0u);

    // Bring RGB to gamma space for the fit math.
    half3 rgb = rgbIn;
    if (isLinear) {
        rgb.r = half(DCRSRGBLinearToGamma(float(rgb.r)));
        rgb.g = half(DCRSRGBLinearToGamma(float(rgb.g)));
        rgb.b = half(DCRSRGBLinearToGamma(float(rgb.b)));
    }

    // RGB ↔ YIQ matrices (NTSC). Used here for tint (Q axis only).
    const half3x3 RGBtoYIQ = half3x3(
        half3(0.299h,  0.587h,  0.114h),
        half3(0.596h, -0.274h, -0.322h),
        half3(0.212h, -0.523h,  0.311h)
    );
    const half3x3 YIQtoRGB = half3x3(
        half3(1.000h,  0.956h,  0.621h),
        half3(1.000h, -0.272h, -0.647h),
        half3(1.000h, -1.105h,  1.702h)
    );

    // Tint on the Q axis only. Clamp keeps Q within the gamut the
    // matrices can represent; prevents runaway overshoot.
    const float tint = clamp(u.tint, -200.0f, 200.0f);
    half3 yiq = RGBtoYIQ * rgb;
    // FIXME(§8.6 Tier 2): 0.5226 is the Q-axis theoretical extreme in
    // YIQ space derived from the RGB→YIQ transform (Rec.709 / NTSC-Japan
    // variant) — this value has a principled origin. The × 0.1 attenuation
    // factor, however, is inherited empirical: it limits the tint slider's
    // effective Q-axis range to 10% of the theoretical max for "UI comfort".
    // The 10% choice has no derivation. Origin of that factor lost with
    // fitting pipeline. Validation: findings-and-plan.md §8.6 Tier 2.
    yiq.b = clamp(yiq.b + half(tint / 100.0f) * 0.5226h * 0.1h,
                  -0.5226h, 0.5226h);
    const half3 rgbTinted = YIQtoRGB * yiq;

    // Warm target and Overlay-blended version for temperature mixing.
    // FIXME(§8.6 Tier 2): Warm target RGB (0.93, 0.54, 0.0) is inherited
    // empirical, approximating a "tungsten/3200K tint" direction in sRGB
    // space. Not derived from any CIE illuminant spectrum or principled
    // color-temperature calibration — just a hand-picked color that
    // "looks warm". Origin lost with fitting pipeline. Validation:
    // findings-and-plan.md §8.6 Tier 2.
    const half3 warm = half3(0.93h, 0.54h, 0.0h);
    half3 blended;
    for (int i = 0; i < 3; i++) {
        blended[i] = dcr_whiteBalanceOverlay(rgbTinted[i], warm[i]);
    }

    // Piecewise-linear Kelvin coefficient. Negative coefficient means
    // cool, positive means warm.
    //
    // FIXME(§8.6 Tier 2): Kelvin slopes 0.0004 (cool side, tempK < 5000)
    // and 0.00006 (warm side, tempK ≥ 5000, 6.67× gentler) are inherited
    // empirical. The cool side's stronger response plausibly reflects
    // greater perceptual sensitivity to blue-shift than warm-shift, but
    // the specific 6.67× ratio has no principled derivation — not from
    // any CIE illuminant curve fit or perceptual luminance model. Pivot
    // 5000K is a reasonable daylight anchor (D50 is 5003K) but also
    // empirical. Origin lost with fitting pipeline. Validation:
    // findings-and-plan.md §8.6 Tier 2.
    const float tempK = clamp(u.temperature, 4000.0f, 8000.0f);
    float tempCoef;
    if (tempK < 5000.0f) {
        tempCoef = 0.0004f * (tempK - 5000.0f);
    } else {
        tempCoef = 0.00006f * (tempK - 5000.0f);
    }

    half3 mixed = mix(rgbTinted, blended, half(tempCoef));

    // SDK output contract: every filter must emit non-negative linear-
    // sRGB. The YIQ tint matrix at extreme `tint` values can drive
    // individual gamma channels to ≈ -0.17 on saturated primaries
    // (verified: red input + tint=+200 → G ≈ -0.116). In linear mode
    // the subsequent `DCRSRGBGammaToLinear` strips negatives via its
    // internal `max(c, 0)`, but in perceptual mode the gamma value is
    // returned directly — propagating the negative downstream and
    // producing the "脏黑斑 / dirty black blob" symptom in any
    // OKLab-using consumer (Saturation, Vibrance) further down the
    // chain. Clamping here at the producer's output enforces the
    // contract for both modes uniformly. HDR overshoot (`> 1`) is
    // preserved.
    mixed = max(mixed, half3(0.0h));

    // Re-linearize before write (no-op in perceptual mode).
    if (isLinear) {
        mixed.r = half(DCRSRGBGammaToLinear(float(mixed.r)));
        mixed.g = half(DCRSRGBGammaToLinear(float(mixed.g)));
        mixed.b = half(DCRSRGBGammaToLinear(float(mixed.b)));
    }

    return mixed;
}
// @dcr:body-end

// Standalone `DCRWhiteBalanceFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `CCDFilter.metal`.
    static let ccdFilter: String = #"""
//
//  CCDFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Rec.709 luma coefficients (0.2126, 0.7152, 0.0722) inlined at use
// site — file-scope `constant` triggered Metal "will not be emitted"
// warning that the SDK's `-warnings-as-errors` CI gate elevates to
// an error.

inline half dcr_ccdSoftLight(half base, half blend) {
    return base + (2.0h * blend - 1.0h) * base * (1.0h - base);
}

struct CCDUniforms {
    float strength;
    float density;
    float caAmount;
    float sharpAmount;
    float grainSize;
    float saturation;
    float sharpStep;
    float caMaxOffset;
};

// ── CCD sensor emulation — compound single-kernel effect ──
//
// Order matters: CA first (color fringing happens on raw sensor), then
// saturation (pre-noise so grain doesn't get saturated), then digital
// noise (sensor noise floor), then luma-channel sharpening sampled from
// original (so noise and CA edges aren't re-hardened), then strength mix.
//
// Step-ordering provenance (§8.1 A.4 verified 2026-04-22, fetched URL):
//
// The "CA → saturation → noise → sharpen" ordering is an **artistic look
// choice**, not a faithful reproduction of a real CCD/CMOS signal chain.
// Confirmed by comparing against openISP reference implementation at
// https://github.com/cruxopen/openISP whose documented ISP pipeline is:
//
//   Bayer:  DPC → BLC → LSC → Anti-aliasing NR → AWB → Bayer-NR
//   RGB:    Demosaic → Gamma → CCM → ColorSpaceConversion
//   YUV:    Luma/Chroma NR → Edge Enhancement → False-color → Hue/Sat
//
// Real ISPs:
//   - **Correct** chromatic aberration at lens/optical level (pre-sensor),
//     not as a mid-pipeline mutation — DCRenderKit instead **adds** CA
//     as an aesthetic "vintage" signature
//   - Apply noise **reduction** at two stages (Bayer + YUV) — DCRenderKit
//     **adds** synthetic grain as a "CCD sensor readout" aesthetic
//   - Place saturation/hue at the very **end** of YUV processing —
//     DCRenderKit puts saturation early (before noise injection) so the
//     grain doesn't get saturation-boosted
//   - Edge Enhancement (sharpening) happens **before** saturation in YUV,
//     not after — DCRenderKit reverses this to keep grain from being
//     re-sharpened
//
// Conclusion: the "CA → sat → noise → sharp" order is a coherent
// **aesthetic narrative** ("lens aberration → color look → sensor
// grain → post-processing polish") but it is NOT a sensor-physical
// simulation. The filter name "CCD" refers to the vintage-camera look,
// not to a simulation of CCD sensor physics. All downstream documents
// and SwiftDoc should describe this as an artistic effect, not a
// sensor model.
//
// Sources (fetched 2026-04-22):
// - github.com/cruxopen/openISP — documented open-source ISP pipeline
// - (§8.4 Audit.4 TODO: cross-reference VSCO / RNI / similar film-sim
//   app technical disclosures when available; none publicly documented
//   at time of verification)

// Body templated on `Tap` so codegen can substitute either
// `DCRRawSourceTap` (default) or a `KernelInlining`-generated
// fused tap that pre-applies an upstream pixelLocal body to each
// sample. Tap.read(int2) handles bounds clamping internally.
//
// @dcr:body-begin DCRCCDBody
template <typename Tap>
inline half3 DCRCCDBody(
    half3 rgbIn,
    constant CCDUniforms& u,
    uint2 gid,
    Tap src
) {
    const float strength    = clamp(u.strength, 0.0f, 1.0f);
    const float density     = clamp(u.density, 0.0f, 1.0f);
    const float caAmount    = clamp(u.caAmount, 0.0f, 1.0f);
    const float sharpAmount = clamp(u.sharpAmount, 0.0f, 1.0f);
    const float grainSize   = max(u.grainSize, 1.0f);
    const float saturation  = u.saturation;                    // 1.0 .. 1.3
    const int   sharpStep   = max(int(round(u.sharpStep)), 1);
    const float caMaxOffset = u.caMaxOffset;

    const int2 pos = int2(gid);

    // 1. Chromatic aberration: horizontal R/B offset.
    half4 color = half4(rgbIn, 1.0h);
    if (caAmount > 0.001f) {
        float caPx = caAmount * caMaxOffset;
        int2 posR = pos + int2(int(-round(caPx)), 0);
        int2 posB = pos + int2(int( round(caPx)), 0);
        color.r = src.read(posR).r;
        color.b = src.read(posB).b;
    }

    // 2. Saturation boost: Rec.709 luma anchor.
    if (saturation > 1.001f) {
        half luma = dot(color.rgb, half3(0.2126h, 0.7152h, 0.0722h));
        color.rgb = luma + (color.rgb - luma) * half(saturation);
        color.rgb = clamp(color.rgb, half3(0.0h), half3(1.0h));
    }

    // 3. Digital noise: block-quantized sin-trick, chromaticity = 0.6.
    if (density > 0.001f) {
        float2 grainPos = floor(float2(gid) / grainSize);
        // Tap.read() clamps out-of-range coords to the texture extent.
        int2 blockCenter = int2(grainPos * grainSize + grainSize * 0.5f);
        float luma = dot(float3(src.read(blockCenter).rgb), float3(0.299f, 0.587f, 0.114f));

        float nR = fract(sin(dot(grainPos, float2(12.9898f, 78.233f)) + luma * 43.0f) * 43758.5453f) * 2.0f - 1.0f;
        float exponent = mix(2.0f, 0.5f, density);
        nR = sign(nR) * pow(abs(nR), exponent);

        half3 blend = half3(0.5h + half(nR) * half(density) * 0.144h);

        float nG = fract(sin(dot(grainPos, float2(93.9898f, 67.345f)) + luma * 37.0f) * 43758.5453f) * 2.0f - 1.0f;
        float nB = fract(sin(dot(grainPos, float2(54.2781f, 31.917f)) + luma * 53.0f) * 43758.5453f) * 2.0f - 1.0f;
        nG = sign(nG) * pow(abs(nG), exponent);
        nB = sign(nB) * pow(abs(nB), exponent);
        blend.g = 0.5h + mix(half(nR), half(nG), 0.6h) * half(density) * 0.144h;
        blend.b = 0.5h + mix(half(nR), half(nB), 0.6h) * half(density) * 0.144h;

        color.r = dcr_ccdSoftLight(color.r, blend.r);
        color.g = dcr_ccdSoftLight(color.g, blend.g);
        color.b = dcr_ccdSoftLight(color.b, blend.b);
    }

    // 4. Luma-channel sharpening from ORIGINAL source.
    //    Sampling from src (not the mutated `color`) means grain and CA
    //    fringes don't get re-sharpened, and only luminance detail is
    //    lifted (keeps color fringing soft).
    if (sharpAmount > 0.001f) {
        const half3 kLumaH = half3(0.2126h, 0.7152h, 0.0722h);
        half4 origCenter = src.read(int2(gid));
        half4 left  = src.read(pos + int2(-sharpStep,  0));
        half4 right = src.read(pos + int2( sharpStep,  0));
        half4 top   = src.read(pos + int2( 0, -sharpStep));
        half4 bot   = src.read(pos + int2( 0,  sharpStep));
        // FIXME(§8.6 Tier 2): × 0.96 = 60% of SharpenFilter's × 1.6 product
        // compression (see SharpenFilter.swift's ×1.6 block). Derivation chain:
        // sharpAmount slider → SharpenFilter would apply × 1.6 → CCD uses
        // 60% of that = × 0.96. The 60% ratio itself is empirical
        // (hand-tuned balance of sharp vs CA vs noise). Transitively
        // depends on the SharpenFilter × 1.6 value.
        half s = half(sharpAmount * 0.96f);  // 60% of SharpenFilter amplitude

        half lumaC = dot(origCenter.rgb, kLumaH);
        half lumaL = dot(left.rgb,  kLumaH);
        half lumaR = dot(right.rgb, kLumaH);
        half lumaT = dot(top.rgb,   kLumaH);
        half lumaB = dot(bot.rgb,   kLumaH);
        half lumaDetail = (lumaC * 4.0h - lumaL - lumaR - lumaT - lumaB) * s;

        color.rgb = clamp(color.rgb + lumaDetail, half3(0.0h), half3(1.0h));
    }

    // 5. Final strength mix between pristine original (rgbIn) and processed.
    return mix(rgbIn, color.rgb, half(strength));
}
// @dcr:body-end

// Standalone `DCRCCDFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `FilmGrainFilter.metal`.
    static let filmGrainFilter: String = #"""
//
//  FilmGrainFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── Hash choice (§8.4 Audit.6, 2026-04-23) ──
//
// The noise hash `fract(sin(dot(pos, (12.9898, 78.233))) · 43758.5453)`
// is the canonical "shadertoy sin-trick" — the exact same formula
// appears across real-time shader film-grain implementations:
//   - lettier.github.io/3d-game-shaders-for-beginners/film-grain.html
//   - shadertoy.com/view/3sGGRz ("Simple Film Grain Shader")
//   - mattdesl/glsl-film-grain (GitHub)
// It is the industry-standard hash for real-time GPU film-grain in
// the shader category. DCR uses it for the same reason: cheap,
// Float32-compatible, well-tested across the category.
//
// Trade-off vs realistic particle-based grain (Audit.6): IPOL 2017
// "Realistic Film Grain Rendering"
// (https://www.ipol.im/pub/art/2017/192/article_lr.pdf) uses stochastic
// silver-halide-crystal models per film stock (Kodak Portra cubic,
// Fuji sigma, etc.). That class of algorithm is an order of magnitude
// more expensive, offline-oriented, and NOT the right fit for the
// real-time camera-preview use case. DCR's category (real-time shader
// film grain) uses the hash approach universally, the sin-trick being
// its canonical realization.
//
// Numerically the sin-trick degrades past ~2¹⁶ argument magnitude due
// to sin precision falloff in Float32, producing visible diagonal /
// cross banding on large textures. Verified clean at 4K on 2026-04-22
// (§8.1 A.3):
//   - Test: FilmGrainPatternTests.test4KFilmGrainSinTrickRowColumnBanding
//   - Method: 4096×4096 uniform 0.5-gray patch, density=1, grainSize=1
//   - Row-mean stddev and column-mean stddev both within 1.1× the
//     i.i.d. noise baseline
//   - No periodic structure detectable by 1D first-moment analysis
//
// If future GPU architecture changes or new regression testing exposes
// banding at higher resolutions, replace with PCG (Jarzynski & Olano
// 2020) or Wyvill hash (GPU Pro 5). Keep the symmetric SoftLight blend
// pipeline (hash-independent).

// Symmetric SoftLight. Derivation: Photoshop's SoftLight uses sqrt() for
// the lighten half and `base*(1-base)` for the darken half, which is not
// symmetric around 0.5 blend and biases mean brightness under noise. By
// perfectly compensating the lighten half, both branches collapse to a
// single closed form with zero bias:
//   result = base + (2·blend - 1) · base · (1 - base)
// Zero branches, zero sqrt, strictly symmetric.
inline half dcr_softLight(half base, half blend) {
    return base + (2.0h * blend - 1.0h) * base * (1.0h - base);
}

struct FilmGrainUniforms {
    float density;        // 0 ... 1
    float grainSize;      // pixels
    float roughness;      // 0 ... 1
    float chromaticity;   // 0 ... 1
};

// Body templated on `Tap` so codegen can substitute either
// `DCRRawSourceTap` (default) or a `KernelInlining`-generated
// fused tap that pre-applies an upstream pixelLocal body to each
// sample. Tap.read(int2) handles bounds clamping internally.
//
// @dcr:body-begin DCRFilmGrainBody
template <typename Tap>
inline half3 DCRFilmGrainBody(
    half3 rgbIn,
    constant FilmGrainUniforms& u,
    uint2 gid,
    Tap src
) {
    const float density      = clamp(u.density, 0.0f, 1.0f);
    const float grainSize    = max(u.grainSize, 1.0f);
    const float roughness    = clamp(u.roughness, 0.0f, 1.0f);
    const float chromaticity = clamp(u.chromaticity, 0.0f, 1.0f);

    if (density < 0.001f) {
        return rgbIn;
    }

    // Quantize grid coordinates so a grainSize×grainSize block shares
    // one noise sample. Preserves visible grain texture at all scales.
    float2 grainPos = floor(float2(gid) / grainSize);

    // Block-center pixel luma (shared across the block so luma-driven
    // randomness doesn't re-break the quantization). Tap.read() clamps
    // out-of-range coords to the texture extent so we don't need to
    // pre-clamp `center` here.
    int2 center = int2(grainPos * grainSize + grainSize * 0.5f);
    float luma = dot(float3(src.read(center).rgb), float3(0.299f, 0.587f, 0.114f));

    // sin-trick noise in [-1, 1].
    float nR = fract(sin(dot(grainPos, float2(12.9898f, 78.233f)) + luma * 43.0f) * 43758.5453f) * 2.0f - 1.0f;

    // Roughness reshape: 0 → soft (concentrated near 0), 1 → coarse.
    float exponent = mix(2.0f, 0.5f, roughness);
    nR = sign(nR) * pow(abs(nR), exponent);

    // SoftLight blend value, `0.5` is neutral. `0.144` is the product-
    // tuned clamp so density=1 stays within perceptual comfort.
    //
    // FIXME(§8.6 Tier 2 archived): × 0.144 is an empirical hand-tuned
    // constant — not derived from any film-grain PSF measurement or a
    // standard grain model (AgX grain, darktable grain module, VSCO
    // reference, etc.). Same 0.144 appears in CCDFilter.metal noise
    // step (intentionally shared). Paired with the Tier 4 snapshot
    // regression baseline, this value is "locked by visual approval"
    // rather than derived from first principles.
    half3 blend = half3(0.5h + half(nR) * half(density) * 0.144h);

    if (chromaticity > 0.001f) {
        float nG = fract(sin(dot(grainPos, float2(93.9898f, 67.345f)) + luma * 37.0f) * 43758.5453f) * 2.0f - 1.0f;
        float nB = fract(sin(dot(grainPos, float2(54.2781f, 31.917f)) + luma * 53.0f) * 43758.5453f) * 2.0f - 1.0f;
        nG = sign(nG) * pow(abs(nG), exponent);
        nB = sign(nB) * pow(abs(nB), exponent);
        blend.g = 0.5h + mix(half(nR), half(nG), half(chromaticity)) * half(density) * 0.144h;
        blend.b = 0.5h + mix(half(nR), half(nB), half(chromaticity)) * half(density) * 0.144h;
    }

    half3 result;
    result.r = dcr_softLight(rgbIn.r, blend.r);
    result.g = dcr_softLight(rgbIn.g, blend.g);
    result.b = dcr_softLight(rgbIn.b, blend.b);

    return result;
}
// @dcr:body-end

// Standalone `DCRFilmGrainFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `LUT3DFilter.metal`.
    static let lut3DFilter: String = #"""
//
//  LUT3DFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Software trilinear: read 8 neighbor texels explicitly, mix() seven times.
// Chosen over `filter::linear` because small LUTs (17³/25³) suffer from
// normalized-coord rounding with the hardware sampler, producing visible
// step artifacts at LUT corners.
inline float4 dcr_sampleLUT3D(texture3d<float, access::read> lut, float3 rgb) {
    const float size = float(lut.get_width());
    const float maxIdx = size - 1.0f;
    const float3 coord = rgb * maxIdx;

    const float3 lo = floor(coord);
    const float3 hi = min(lo + 1.0f, maxIdx);
    const float3 frac = coord - lo;

    const uint3 c0 = uint3(lo);
    const uint3 c1 = uint3(hi);

    const float4 v000 = lut.read(uint3(c0.x, c0.y, c0.z));
    const float4 v100 = lut.read(uint3(c1.x, c0.y, c0.z));
    const float4 v010 = lut.read(uint3(c0.x, c1.y, c0.z));
    const float4 v110 = lut.read(uint3(c1.x, c1.y, c0.z));
    const float4 v001 = lut.read(uint3(c0.x, c0.y, c1.z));
    const float4 v101 = lut.read(uint3(c1.x, c0.y, c1.z));
    const float4 v011 = lut.read(uint3(c0.x, c1.y, c1.z));
    const float4 v111 = lut.read(uint3(c1.x, c1.y, c1.z));

    const float4 m00 = mix(v000, v100, frac.x);
    const float4 m10 = mix(v010, v110, frac.x);
    const float4 m01 = mix(v001, v101, frac.x);
    const float4 m11 = mix(v011, v111, frac.x);

    const float4 m0 = mix(m00, m10, frac.y);
    const float4 m1 = mix(m01, m11, frac.y);

    return mix(m0, m1, frac.z);
}

// Triangular dither — sum of two independent uniforms hashed from pixel
// position. Amplitude ±1/255 (one 8-bit step), decorrelates quantization
// noise from the signal for banding-free downstream 8-bit writes.
inline half3 dcr_triangularDither(uint2 pos, half3 color) {
    float2 seed = float2(pos) * float2(12.9898f, 78.233f);
    float noise1 = fract(sin(dot(seed, float2(1.0f, 1.0f))) * 43758.5453f);
    float noise2 = fract(sin(dot(seed, float2(0.3183f, 0.7071f))) * 22578.1459f);
    float tri = noise1 - noise2;
    return color + half3(half(tri) * half(1.0f / 255.0f));
}

struct LUT3DUniforms {
    float intensity;      // 0 ... 1
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/SRGBGamma.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/SRGBGamma.metal. Edit one copy → edit every
// mirror. Grep:
//
//     // MIRROR: Foundation/SRGBGamma.metal

inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

// ## Color-space branching
//
// `.cube` files — the universal film-emulation exchange format — are
// defined as functions of **gamma-encoded** input RGB. The cube values
// themselves are the gamma-encoded outputs the colorist intended. The
// whole mapping lives entirely in display (perceptual) space.
//
// In `.linear` mode our inputs are linear-light floats. Looking them up
// in a gamma-space cube reads from an arbitrary, nonsense table location.
// The fix is the same gamma-wrap pattern used by the fitted tone filters:
// un-linearize → run the cube sample → re-linearize the output → mix.
//
// The `mix(src, lut, intensity)` still operates on the original input
// space (linear in `.linear` mode, gamma in `.perceptual` mode), which is
// the correct domain for the intensity blend. In `.linear` mode we
// re-linearize `lutColor` before mixing so both ends of the mix live in
// the same space.

// @dcr:body-begin DCRLUT3DBody
inline half3 DCRLUT3DBody(
    half3 rgbIn,
    constant LUT3DUniforms& u,
    uint2 gid,
    texture3d<float, access::read> lut
) {
    const bool isLinear = (u.isLinearSpace != 0u);

    // Coords used to index the cube must be in gamma space (the cube's
    // native domain). In linear mode we un-linearize first.
    float3 rgbForLUT = clamp(float3(rgbIn), 0.0f, 1.0f);
    if (isLinear) {
        rgbForLUT.r = DCRSRGBLinearToGamma(rgbForLUT.r);
        rgbForLUT.g = DCRSRGBLinearToGamma(rgbForLUT.g);
        rgbForLUT.b = DCRSRGBLinearToGamma(rgbForLUT.b);
    }

    float4 lutColor = dcr_sampleLUT3D(lut, rgbForLUT);

    // The LUT output is in gamma space. In linear mode we re-linearize
    // before mixing with the linear input.
    if (isLinear) {
        lutColor.r = DCRSRGBGammaToLinear(lutColor.r);
        lutColor.g = DCRSRGBGammaToLinear(lutColor.g);
        lutColor.b = DCRSRGBGammaToLinear(lutColor.b);
    }

    const float mixFactor = clamp(u.intensity, 0.0f, 1.0f);
    const half3 result = mix(rgbIn, half3(lutColor.rgb), half(mixFactor));

    return dcr_triangularDither(gid, result);
}
// @dcr:body-end

// Standalone `DCRLUT3DFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#

    /// Verbatim text of `NormalBlendFilter.metal`.
    static let normalBlendFilter: String = #"""
//
//  NormalBlendFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Manual bilinear read — lets the overlay be any resolution without
// requiring the caller to bind a sampler (ComputeDispatcher's binding
// convention uses access::read for additional inputs). On dimension-
// matched overlays the bilinear call collapses to a single texel read
// because frac(coord) == 0.
inline half4 dcr_blendBilinear(texture2d<half, access::read> tex, float2 coord) {
    int2 p = int2(floor(coord));
    float2 f = fract(coord);
    int maxX = int(tex.get_width()) - 1;
    int maxY = int(tex.get_height()) - 1;
    half4 c00 = tex.read(uint2(clamp(p.x,     0, maxX), clamp(p.y,     0, maxY)));
    half4 c10 = tex.read(uint2(clamp(p.x + 1, 0, maxX), clamp(p.y,     0, maxY)));
    half4 c01 = tex.read(uint2(clamp(p.x,     0, maxX), clamp(p.y + 1, 0, maxY)));
    half4 c11 = tex.read(uint2(clamp(p.x + 1, 0, maxX), clamp(p.y + 1, 0, maxY)));
    return mix(mix(c00, c10, half(f.x)), mix(c01, c11, half(f.x)), half(f.y));
}

struct NormalBlendUniforms {
    float intensity;   // 0 ... 1
};

// @dcr:body-begin DCRNormalBlendBody
//
// Note: the uber-kernel convention for `.pixelLocalWithOverlay`
// passes rgba4 (not half3) because Porter-Duff compositing needs
// the alpha channel. The body therefore takes `half4 rgbaIn` and
// returns `half4`. Codegen's signature stencil for this shape
// will reflect that.
inline half4 DCRNormalBlendBody(
    half4 rgbaIn,
    constant NormalBlendUniforms& u,
    uint2 gid,
    texture2d<half, access::read> overlay,
    uint2 outputSize
) {
    const uint outW = outputSize.x;
    const uint outH = outputSize.y;

    // Map the output pixel-center into the overlay texture's coord
    // space. Bilinear handles dimension mismatch; when dimensions
    // match exactly, coord lands on a texel center and frac == 0.
    const float2 coord = (float2(gid) + 0.5f)
        * float2(float(overlay.get_width()) / float(outW),
                 float(overlay.get_height()) / float(outH))
        - 0.5f;
    const half4 over = dcr_blendBilinear(overlay, coord);

    // Porter-Duff "source over" compositing of overlay on input.
    half4 composited;
    composited.rgb = over.rgb + rgbaIn.rgb * rgbaIn.a * (1.0h - over.a);
    composited.a   = over.a   + rgbaIn.a              * (1.0h - over.a);

    const half t = half(clamp(u.intensity, 0.0f, 1.0f));
    return mix(rgbaIn, composited, t);
}
// @dcr:body-end

// Standalone `DCRBlendNormalFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
"""#
}
