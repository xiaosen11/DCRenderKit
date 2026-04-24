//
//  ExposureFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── ExposureFilter — symmetric linear gain with Reinhard rolloff ──
//
// gain = exp2(exposure · 0.7 · EV_RANGE),  EV_RANGE = 4.25
//
// Positive (exposure > 0, gain > 1):
//   Extended Reinhard tonemap prevents highlight overshoot.
//   Reference: Reinhard et al., SIGGRAPH 2002
//   "Photographic Tone Reproduction". Whitepoint w = 0.95·gain.
//   mapped = x·gain · (1 + x·gain / w²) / (1 + x·gain)
//
// Negative (exposure < 0, gain < 1):
//   Pure linear gain y = clamp(x · gain, 0, 1).
//   gain < 1 ⇒ x·gain ≤ gain ≤ 1: no overshoot to protect against,
//   so no tone-mapper is warranted. This is the physically exact
//   "less light reaches the sensor" operation. The prior
//   `A·x^γ + B·x` fitted curve was polynomial shaping bolted on
//   the same primitive; replaced with the linear form.
//
// Identity at exposure = 0 (both branches gated by dead-zone).
//
// ## Color-space branching
//
// Both branches are defined in linear-light. How the shader gets
// there depends on SDK configuration:
//
//   u.isLinearSpace == 0 (perceptual mode):
//     Input texture stores sRGB-gamma encoded floats. Shader
//     linearizes with the canonical IEC 61966-2-1 piecewise helper
//     (MIRROR of Foundation/SRGBGamma.metal), applies the branch,
//     then re-encodes. Output stays gamma-encoded.
//
//   u.isLinearSpace == 1 (linear mode):
//     Input texture is already linear; the branches run directly.
//     Output stays linear (drawable bgra8Unorm_srgb handles encoding).

struct ExposureUniforms {
    float exposure;       // -1.0 ... +1.0
    uint  isLinearSpace;  // 1 if the input is linear-light; 0 if gamma-encoded.
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

// @dcr:body-begin DCRExposureBody
inline half3 DCRExposureBody(half3 rgbIn, constant ExposureUniforms& u) {
    half3 color = rgbIn;

    // Product compression: slider ±1 maps to 70% of raw fit magnitude.
    const float exposure = clamp(u.exposure, -1.0f, 1.0f) * 0.7f;
    const bool isLinear = (u.isLinearSpace != 0u);

    if (exposure > 0.001f) {
        // Positive: Extended Reinhard in linear-light space.
        // FIXME(§8.6 Tier 2 archived): EV_RANGE = 4.25 maps slider ±1
        // to ±4.25 EV — slightly narrower than Lightroom's ±5 EV
        // standard. Hand-chosen for "commercial slider feel", not a
        // derived number.
        //
        // `white * 0.95` is the Extended Reinhard white-point offset —
        // keeps the mapped max slightly below pure gain to avoid
        // numerical saturation at the peak. The 0.95 is an empirical
        // safety margin, not a principled derivation.
        const float EV_RANGE = 4.25f;
        const float gain = pow(2.0f, exposure * EV_RANGE);
        const float white = gain * 0.95f;
        const float white2 = white * white;

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float linear = isLinear ? max(c, 0.0f)
                                    : DCRSRGBGammaToLinear(c);
            float gained = linear * gain;
            float mapped = gained * (1.0f + gained / white2) / (1.0f + gained);
            float clamped = clamp(mapped, 0.0f, 1.0f);
            color[ch] = half(isLinear ? clamped
                                      : DCRSRGBLinearToGamma(clamped));
        }
    } else if (exposure < -0.001f) {
        // Negative: pure linear gain in linear-light space.
        // gain < 1 ⇒ x·gain ∈ [0, gain) ⊂ [0, 1): no overshoot to
        // protect against, so no tone-mapper needed. "Less light
        // reaches the sensor" in physical terms.
        const float EV_RANGE = 4.25f;
        const float gain = pow(2.0f, exposure * EV_RANGE);

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float linear = isLinear ? max(c, 0.0f)
                                    : DCRSRGBGammaToLinear(c);
            float gained = linear * gain;
            float clamped = clamp(gained, 0.0f, 1.0f);
            color[ch] = half(isLinear ? clamped
                                      : DCRSRGBLinearToGamma(clamped));
        }
    }

    return color;
}
// @dcr:body-end

// The `DCRExposureFilter` kernel previously shipped here was
// retired in Phase 5 step 5.5 of the pipeline-compiler refactor.
// Every dispatch — including single-filter — now flows through the
// runtime-compiled uber kernel produced by `MetalSourceBuilder`
// from the body function above. See
// `docs/pipeline-compiler-design.md` §4 for the body-function-only
// shader convention and `Tests/DCRenderKitTests/LegacyKernels/`
// for the frozen pre-refactor copy kept as a Phase 7 parity gate.
