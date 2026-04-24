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
// Saturation kernel
// ═══════════════════════════════════════════════════════════════════

struct SaturationUniforms {
    float saturation;
};

// @dcr:body-begin DCRSaturationBody
inline half3 DCRSaturationBody(half3 rgbIn, constant SaturationUniforms& u) {
    const float s = clamp(u.saturation, 0.0f, 2.0f);

    // linear sRGB → OKLCh
    const float3 lab = DCRLinearSRGBToOKLab(float3(rgbIn));
    float3 lch = DCROKLabToOKLCh(lab);

    // Uniform chroma scaling (Adobe-like saturation — no hue protect).
    lch.y *= s;

    // Keep (L, h) fixed; reduce C only as much as the gamut requires.
    lch = DCROKLChGamutClamp(lch);

    // OKLCh → linear sRGB
    const float3 lab_out = DCROKLChToOKLab(lch);
    const float3 rgb = DCROKLabToLinearSRGB(lab_out);

    return half3(rgb);
}
// @dcr:body-end

kernel void DCRSaturationFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant SaturationUniforms& u        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    const half4 c = input.read(gid);
    output.write(half4(DCRSaturationBody(c.rgb, u), c.a), gid);
}
