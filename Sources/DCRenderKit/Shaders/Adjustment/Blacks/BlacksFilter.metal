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
