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

kernel void DCRLegacyContrastFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant ContrastUniforms& u          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 original = input.read(gid);
    half3 color = original.rgb;

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

    output.write(half4(color, original.a), gid);
}
