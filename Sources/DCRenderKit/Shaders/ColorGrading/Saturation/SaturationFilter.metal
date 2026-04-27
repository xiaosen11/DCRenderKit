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
    const float h = atan2(lab.z, lab.y);
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
// Needed for the perceptual-mode branch — the body linearises
// gamma-encoded input before running OKLab math (which is calibrated
// for linear sRGB by Ottosson 2020), then re-encodes on output.
// Same canonical-helper-mirror discipline as the other tone filters
// (Exposure, Contrast, Whites, Blacks, WhiteBalance).

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
    uint  isLinearSpace;   // 1 = linear input; 0 = gamma-encoded.
};

// @dcr:body-begin DCRSaturationBody
inline half3 DCRSaturationBody(half3 rgbIn, constant SaturationUniforms& u) {
    const float s = clamp(u.saturation, 0.0f, 2.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    // OKLab is defined for non-negative linear sRGB (Ottosson 2020).
    // Two-stage input normalisation, both required:
    //
    //  Stage 1 — sub-gamut clamp (`x < 0` → `0`):
    //    Sub-gamut overshoot like `(-0.05, -0.05, 0.5)` from upstream
    //    WhiteBalance YIQ-tint extremes passes cleanly through
    //    OKLab's `sign(x)·pow(abs(x),1/3)` but the resulting `L`
    //    mixes positive coefficients across signed `l_/m_/s_`, no
    //    longer matching the pixel's perceptual brightness. The
    //    gamut clamp then drives `C` toward zero at this wrong `L`,
    //    emitting near-black grey — the "脏黑斑 / dirty black blob"
    //    symptom. Treat sub-gamut input as no light.
    //
    //  Stage 2 — gamma → linear (perceptual mode only):
    //    In `.perceptual` mode the source texture carries sRGB-gamma
    //    bytes (raw `bgra8Unorm` from a JPEG / PNG loader). OKLab
    //    fed gamma values produces a wrong `L` for chromatic pixels
    //    (gamma 0.5 ≈ linear 0.21 — different OKLab brightness).
    //    Linearise via IEC 61966-2-1 piecewise sRGB so OKLab
    //    operates on the values it is calibrated for. The helper's
    //    own `max(c, 0)` makes Stage 1 a no-op on this branch — but
    //    keeping it explicit on the linear branch makes the
    //    sanitisation contract visible at a glance, instead of
    //    relying on a "buried inside the helper" guarantee.
    //
    // HDR overshoot (`> 1`) is preserved unchanged because OKLab is
    // defined for `L > 1` and the gamut clamp drives `C` to 0,
    // emitting a bright grey — the intended HDR behaviour.
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

    // Re-encode if the pipeline carries gamma-encoded values.
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
