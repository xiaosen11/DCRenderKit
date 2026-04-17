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

struct ClarityUniforms {
    float intensity;   // -1.0 ... +1.0, already product-compressed
};

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
    half3 detail = orig.rgb - baseColor.rgb;

    half3 result;
    if (intensity >= 0.0f) {
        result = orig.rgb + detail * half(intensity * 1.5f);
    } else {
        result = mix(orig.rgb, baseColor.rgb, half(-intensity * 0.7f));
    }

    result = clamp(result, half3(0.0h), half3(1.0h));
    output.write(half4(result, orig.a), gid);
}
