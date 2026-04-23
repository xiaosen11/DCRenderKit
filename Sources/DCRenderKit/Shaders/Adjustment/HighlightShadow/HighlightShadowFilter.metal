//
//  HighlightShadowFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

constant float3 kDCRHighlightShadowLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

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

// ── DCRGuidedApplyRatio ──
//
// Bilinearly upsample (a, b) from low-res to full-res, compute
// baseLuma = a·I + b, then map baseLuma through two smoothstep
// weight windows (one for highlights, one for shadows) and produce
// a per-pixel ratio value. The ratio is written to all RGB channels
// so the final kernel can simply read `.r` (uniform for read ease).
//
// Smoothstep window design (gamma-space anchors):
//   - Highlight window:  baseLuma ∈ [0.25, 0.85] ramps 0 → 1
//   - Shadow window:     baseLuma ∈ [0.15, 0.75] ramps 1 → 0
//   (inverted with 1 - smoothstep)
// Overlap in the midtones is intentional so adjacent-luminance
// regions fade smoothly rather than step-switching.
//
// ## Color-space branching
//
// The window anchors above are gamma-space luminance targets (they were
// chosen so the "highlight slider" reaches 100% effect at a luma where
// the scene feels visually "highlights", i.e. perceptually ≥ ~0.85 gray).
// In .linear mode `baseLuma` comes from guided-filter smoothing of
// linear-light luminance, whose [0,1] distribution skews heavily dark
// (gamma 0.25 ≈ linear 0.047). Comparing linear baseLuma to gamma-calibrated
// window endpoints produces:
//   - highlight window triggers only at linear ≥ 0.25 = gamma ≥ 0.53
//     → midtones never get "highlight" treatment → user-reported F3
//     "对高光不够敏感, 缺层次感"
// Fix: un-linearize baseLuma to gamma space before smoothstep comparison.
// Windows stay calibrated; baseLuma is mapped to their native domain.
//
// Product compression: × 0.35 on highlights, × 0.50 on shadows.
// Final ratio clamped to [0.3, 3.0] to avoid runaway multiplications.

struct HighlightShadowRatioUniforms {
    float highlights;     // -1.0 ... +1.0
    float shadows;
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

struct HighlightShadowApplyUniforms {
    uint  isLinearSpace;  // matches RatioUniforms; needed here so the
                          // multiply-then-saturate step can wrap gamma.
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

    // In linear mode baseLuma lives in linear-light; project it to
    // gamma space so the smoothstep windows below hit their calibrated
    // tonal zones.
    const bool isLinear = (u.isLinearSpace != 0u);
    float baseLumaForWindows = isLinear ? DCRSRGBLinearToGamma(baseLuma) : baseLuma;

    // Two smoothstep windows. The inline smoothstep keeps the shader
    // deterministic across GPUs that differ on the `smoothstep` intrinsic.
    //
    // FIXME(§8.6 Tier 2 archived): Window endpoints [0.25, 0.85] /
    // [0.15, 0.75] are empirical hand-tuned anchors that happen to
    // track Ansel Adams' Zone System midpoints (Norman Koren's
    // simplified 8-bit table: Zone III ≈ 64/255 = 0.251; Zone IX ≈
    // 218/255 = 0.855; Zone II ≈ 38/255 = 0.149; Zone VIII ≈ 192/255
    // = 0.753 — all within 0.005 of the anchor values). Contract
    // verification lives in `docs/contracts/highlight_shadow.md`
    // (Zone targeting C.3 + halo-free C.4).
    float t_h = clamp((baseLumaForWindows - 0.25f) / (0.85f - 0.25f), 0.0f, 1.0f);
    float h_weight = t_h * t_h * (3.0f - 2.0f * t_h);

    float t_s = clamp((baseLumaForWindows - 0.15f) / (0.75f - 0.15f), 0.0f, 1.0f);
    float s_weight = 1.0f - t_s * t_s * (3.0f - 2.0f * t_s);

    // FIXME(§8.6 Tier 2 archived): Product compression × 0.35
    // (highlight) and × 0.50 (shadow) plus ratio clamp [0.3, 3.0] are
    // empirical hand-tuned constants. The clamp bounds prevent runaway
    // multiplication (safety); the × 0.35 / × 0.50 ratios encode a
    // "visible but not harsh" slider feel with no principled
    // derivation. Contract verification for the zone-targeting / halo-
    // free behaviour lives in `docs/contracts/highlight_shadow.md`.
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
//
// The `ratio` scalar was designed to multiply gamma-space RGB (that's the
// domain where `0.35 * highlights` = "35% highlight boost" makes the
// fitted visual sense). In `.linear` mode we un-linearize RGB, do the
// multiply + saturation compensation in gamma space, then re-linearize.
// Without this wrap, multiplying linear RGB by a gamma-calibrated ratio
// under-corrects highlights (linear·ratio < equivalent gamma·ratio) and
// the "slightly desaturate on brighten" compensation lands on the wrong
// chroma coordinates.

kernel void DCRHighlightShadowApply(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  original [[texture(1)]],
    texture2d<half, access::read>  ratioTex [[texture(2)]],
    constant HighlightShadowApplyUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const half4 orig = original.read(gid);
    const float ratio = float(ratioTex.read(gid).r);
    const bool isLinear = (u.isLinearSpace != 0u);

    // Bring RGB into gamma space for the multiply + sat comp.
    float3 rgb = float3(orig.rgb);
    if (isLinear) {
        rgb.r = DCRSRGBLinearToGamma(rgb.r);
        rgb.g = DCRSRGBLinearToGamma(rgb.g);
        rgb.b = DCRSRGBLinearToGamma(rgb.b);
    }

    float3 result = rgb * ratio;

    // FIXME(§8.6 Tier 2 archived): Saturation compensation slope × 0.25
    // and clamp bounds [0.8, 1.3] are empirical hand-tuned constants.
    // The "brighten → slight desat / darken → slight sat" heuristic is
    // qualitatively reasonable but the specific 25 % slope and ±30 %
    // clamp range are not derived from a chroma-compensation model.
    float satFactor = clamp(1.0f + (1.0f - ratio) * 0.25f, 0.8f, 1.3f);
    float resLuma = dot(result, kDCRHighlightShadowLumaRec709);
    result = float3(resLuma) + (result - float3(resLuma)) * satFactor;

    result = clamp(result, 0.0f, 1.0f);

    if (isLinear) {
        result.r = DCRSRGBGammaToLinear(result.r);
        result.g = DCRSRGBGammaToLinear(result.g);
        result.b = DCRSRGBGammaToLinear(result.b);
    }

    output.write(half4(half3(result), orig.a), gid);
}
