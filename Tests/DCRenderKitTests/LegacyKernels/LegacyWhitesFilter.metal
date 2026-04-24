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

kernel void DCRLegacyWhitesFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant WhitesUniforms& u            [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 original = input.read(gid);
    half3 color = original.rgb;

    const float whites = clamp(u.whites, -1.0f, 1.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    // Filmic shoulder scale. slider = 0 ⇒ ε = 1 ⇒ identity.
    // slider > 0 ⇒ ε > 1 ⇒ highlight lift; slider < 0 ⇒ ε < 1 ⇒ crush.
    const float eps = exp2(whites * 1.0f);

    if (abs(whites) <= 0.001f) {
        output.write(original, gid);
        return;
    }

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

    output.write(half4(color, original.a), gid);
}
