//
//  ClarityFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

constant float3 kDCRClarityLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

// ── DCRClarityComputeBase ──
//
// Bilinearly upsample the smoothed (a, b) coefficients from guided
// filter's 1/4-res output to full resolution, compute the per-pixel
// base luminance `baseLuma = a·I + b`, then rescale RGB by
// `baseLuma / origLuma` so the base texture carries edge-preserving
// luminance AND the original's colour.
//
// Keeping chroma unchanged means the final pass can detect "how much
// luminance detail was smoothed out" via `original - base` without
// leaking chromatic content into the detail signal.

kernel void DCRClarityComputeBase(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  original [[texture(1)]],
    texture2d<half, access::read>  abLowRes [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint fullW = output.get_width();
    const uint fullH = output.get_height();
    if (gid.x >= fullW || gid.y >= fullH) return;

    const int abW = int(abLowRes.get_width());
    const int abH = int(abLowRes.get_height());
    const float2 srcCoord = float2(
        (float(gid.x) + 0.5f) * float(abW) / float(fullW) - 0.5f,
        (float(gid.y) + 0.5f) * float(abH) / float(fullH) - 0.5f
    );
    const int2 p00 = int2(floor(srcCoord));
    const float2 frac = srcCoord - float2(p00);
    const int2 c00 = clamp(p00,             int2(0), int2(abW - 1, abH - 1));
    const int2 c10 = clamp(p00 + int2(1, 0), int2(0), int2(abW - 1, abH - 1));
    const int2 c01 = clamp(p00 + int2(0, 1), int2(0), int2(abW - 1, abH - 1));
    const int2 c11 = clamp(p00 + int2(1, 1), int2(0), int2(abW - 1, abH - 1));

    half4 s00 = abLowRes.read(uint2(c00));
    half4 s10 = abLowRes.read(uint2(c10));
    half4 s01 = abLowRes.read(uint2(c01));
    half4 s11 = abLowRes.read(uint2(c11));

    half4 ab = mix(mix(s00, s10, half(frac.x)),
                   mix(s01, s11, half(frac.x)),
                   half(frac.y));

    float a = float(ab.r);
    float b = float(ab.g);

    const half4 orig = original.read(gid);
    float origLuma = dot(float3(orig.rgb), kDCRClarityLumaRec709);
    float baseLuma = a * origLuma + b;

    float ratio = (origLuma > 0.001f) ? (baseLuma / origLuma) : 1.0f;
    half3 baseRGB = orig.rgb * half(ratio);

    output.write(half4(baseRGB, orig.a), gid);
}

// ── DCRClarityApply ──
//
// Positive: `output = original + detail · intensity · 1.5`
//   — amplifies the mid-frequency component that was removed by the
//   guided filter. ×1.5 gain is hand-tuned empirical; no
//   independent Weber-Fechner measurement backs "perceptually-linear
//   slider response". Documented as tech debt in docs/contracts/clarity.md.
//
// Negative: `output = mix(original, base, |intensity| · 0.7)`
//   — blends toward the smooth edge-preserving base. ×0.7 is similarly
//   hand-tuned empirical; keeps extreme from fully flattening.
//
// ## Color-space branching
//
// Local contrast is a perceptual quantity; the `detail` signal
// (original − base) was tuned so that the product compression (×1.5 /
// ×0.7) produces perceptually-linear slider response. In `.linear` mode
// the raw subtraction happens on linear-light values, where `detail`
// skews larger in highlights and smaller in shadows — slider response
// gets non-uniform across tonal zones. Fix: wrap subtract + add in
// gamma space.

struct ClarityUniforms {
    float intensity;      // -1.0 ... +1.0, already product-compressed
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

kernel void DCRClarityApply(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  original [[texture(1)]],
    texture2d<half, access::read>  base     [[texture(2)]],
    constant ClarityUniforms& u             [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const half4 orig = original.read(gid);
    const float intensity = clamp(u.intensity, -1.0f, 1.0f);

    if (abs(intensity) <= 0.001f) {
        output.write(orig, gid);
        return;
    }

    const half4 baseColor = base.read(gid);
    const bool isLinear = (u.isLinearSpace != 0u);

    // Bring both signals to gamma space so `detail` is computed in the
    // domain where the product-compression constants were fit.
    float3 origRGB = float3(orig.rgb);
    float3 baseRGB = float3(baseColor.rgb);
    if (isLinear) {
        origRGB.r = DCRSRGBLinearToGamma(origRGB.r);
        origRGB.g = DCRSRGBLinearToGamma(origRGB.g);
        origRGB.b = DCRSRGBLinearToGamma(origRGB.b);
        baseRGB.r = DCRSRGBLinearToGamma(baseRGB.r);
        baseRGB.g = DCRSRGBLinearToGamma(baseRGB.g);
        baseRGB.b = DCRSRGBLinearToGamma(baseRGB.b);
    }

    float3 detail = origRGB - baseRGB;

    // FIXME(§8.6 Tier 2 archived): Product compression factors × 1.5
    // (positive) and × 0.7 (negative) are empirical hand-tuned constants
    // with no Weber-Fechner linearity measurement backing them. Contract
    // verification lives in `docs/contracts/clarity.md` (FFT spectral
    // selectivity + dynamic-range preservation) rather than a slider-
    // linearity claim.
    float3 result;
    if (intensity >= 0.0f) {
        result = origRGB + detail * (intensity * 1.5f);
    } else {
        result = mix(origRGB, baseRGB, -intensity * 0.7f);
    }

    result = clamp(result, 0.0f, 1.0f);

    if (isLinear) {
        result.r = DCRSRGBGammaToLinear(result.r);
        result.g = DCRSRGBGammaToLinear(result.g);
        result.b = DCRSRGBGammaToLinear(result.b);
    }

    output.write(half4(half3(result), orig.a), gid);
}
