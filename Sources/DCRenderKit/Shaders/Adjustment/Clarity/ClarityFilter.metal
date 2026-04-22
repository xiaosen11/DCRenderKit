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
//   guided filter. ×1.5 gain compensates for intensity's product
//   compression so the perceived effect tracks the slider linearly.
//
// Negative: `output = mix(original, base, |intensity| · 0.7)`
//   — blends toward the smooth edge-preserving base. ×0.7 keeps the
//   extreme from fully flattening into the base (preserves some
//   detail at slider = -100).
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

// IEC 61966-2-1 piecewise sRGB curves (§8.1 A.1). See ContrastFilter.metal
// for rationale — this is the per-filter copy of the same formulas.
inline float dcr_clarityLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float dcr_clarityGammaToLinear(float c) {
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
        origRGB.r = dcr_clarityLinearToGamma(origRGB.r);
        origRGB.g = dcr_clarityLinearToGamma(origRGB.g);
        origRGB.b = dcr_clarityLinearToGamma(origRGB.b);
        baseRGB.r = dcr_clarityLinearToGamma(baseRGB.r);
        baseRGB.g = dcr_clarityLinearToGamma(baseRGB.g);
        baseRGB.b = dcr_clarityLinearToGamma(baseRGB.b);
    }

    float3 detail = origRGB - baseRGB;

    // FIXME(§8.6 Tier 2 + §8.2 A+.2): Product compression factors × 1.5
    // (positive) and × 0.7 (negative) are inherited empirical from Harbeth.
    // Doc comment above claims "perceptually-linear slider response" but
    // that's an unverified assertion — no Weber-Fechner linearity
    // measurement exists for Clarity's slider. Original fit pipeline lost.
    // Validation: findings-and-plan.md §8.6 Tier 2 (SSIM vs Pixel Cake) +
    // §8.2 A+.2 contract formalization (FFT spectral selectivity).
    float3 result;
    if (intensity >= 0.0f) {
        result = origRGB + detail * (intensity * 1.5f);
    } else {
        result = mix(origRGB, baseRGB, -intensity * 0.7f);
    }

    result = clamp(result, 0.0f, 1.0f);

    if (isLinear) {
        result.r = dcr_clarityGammaToLinear(result.r);
        result.g = dcr_clarityGammaToLinear(result.g);
        result.b = dcr_clarityGammaToLinear(result.b);
    }

    output.write(half4(half3(result), orig.a), gid);
}
