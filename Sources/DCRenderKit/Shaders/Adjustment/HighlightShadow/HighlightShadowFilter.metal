//
//  HighlightShadowFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

constant float3 kDCRHighlightShadowLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

// ── DCRGuidedApplyRatio ──
//
// Bilinearly upsample (a, b) from low-res to full-res, compute
// baseLuma = a·I + b, then map baseLuma through two smoothstep
// weight windows (one for highlights, one for shadows) and produce
// a per-pixel ratio value. The ratio is written to all RGB channels
// so the final kernel can simply read `.r` (uniform for read ease).
//
// Smoothstep window design:
//   - Highlight window:  baseLuma ∈ [0.25, 0.85] ramps 0 → 1
//   - Shadow window:     baseLuma ∈ [0.15, 0.75] ramps 1 → 0
//   (inverted with 1 - smoothstep)
// Overlap in the midtones is intentional so adjacent-luminance
// regions fade smoothly rather than step-switching.
//
// Product compression: × 0.35 on highlights, × 0.50 on shadows.
// Final ratio clamped to [0.3, 3.0] to avoid runaway multiplications.

struct HighlightShadowRatioUniforms {
    float highlights;   // -1.0 ... +1.0
    float shadows;
};

kernel void DCRGuidedApplyRatio(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  original [[texture(1)]],
    texture2d<half, access::read>  abLowRes [[texture(2)]],
    constant HighlightShadowRatioUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint fullW = output.get_width();
    const uint fullH = output.get_height();
    if (gid.x >= fullW || gid.y >= fullH) return;

    const float highlights = clamp(u.highlights, -1.0f, 1.0f);
    const float shadows    = clamp(u.shadows,    -1.0f, 1.0f);

    // Bilinear upsample of (a, b).
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
    float origLuma = dot(float3(orig.rgb), kDCRHighlightShadowLumaRec709);
    float baseLuma = a * origLuma + b;

    // Two smoothstep windows. The inline smoothstep keeps the shader
    // deterministic across GPUs that differ on the `smoothstep` intrinsic.
    float t_h = clamp((baseLuma - 0.25f) / (0.85f - 0.25f), 0.0f, 1.0f);
    float h_weight = t_h * t_h * (3.0f - 2.0f * t_h);

    float t_s = clamp((baseLuma - 0.15f) / (0.75f - 0.15f), 0.0f, 1.0f);
    float s_weight = 1.0f - t_s * t_s * (3.0f - 2.0f * t_s);

    float ratio = 1.0f + highlights * h_weight * 0.35f
                       + shadows    * s_weight * 0.50f;
    ratio = clamp(ratio, 0.3f, 3.0f);

    output.write(half4(half(ratio), half(ratio), half(ratio), 1.0h), gid);
}

// ── DCRHighlightShadowApply ──
//
// Final pass: multiply original RGB by ratio, then compensate
// saturation. Brightening (ratio > 1) slightly desaturates (prevents
// chroma over-boost); darkening (ratio < 1) slightly saturates (restores
// color that would otherwise feel muddy). Saturation factor is itself
// clamped to [0.8, 1.3] to avoid perceptual swings.

kernel void DCRHighlightShadowApply(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  original [[texture(1)]],
    texture2d<half, access::read>  ratioTex [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const half4 orig = original.read(gid);
    const float ratio = float(ratioTex.read(gid).r);

    half3 result = orig.rgb * half(ratio);

    float satFactor = clamp(1.0f + (1.0f - ratio) * 0.25f, 0.8f, 1.3f);
    float resLuma = dot(float3(result), kDCRHighlightShadowLumaRec709);
    result = half3(resLuma) + (result - half3(resLuma)) * half(satFactor);

    result = clamp(result, half3(0.0h), half3(1.0h));
    output.write(half4(result, orig.a), gid);
}
