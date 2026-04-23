//
//  ContrastFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── ContrastFilter — luma-mean adaptive cubic pivot ──
//
// Model: y = clamp(x + k * x * (1 - x) * (x - pivot), 0, 1)
//   k     = (-0.356 * lumaMean + 2.289) * contrast
//   pivot =  0.381 * lumaMean + 0.377
// Per-channel application.
//
// Fit against ±100 reference exports from a consumer photo-editing app
// across 3 scenes (bridge / castle / tower, mean luma 0.29 / 0.40 /
// 0.60), in *perceptual* (sRGB-gamma) space. Joint cross-scene average
// MSE = 52.1 (≈ 7.2 levels / 2.8%).
//
// ## Color-space branching
//
// u.isLinearSpace == 0: apply the curve directly on gamma-encoded floats
//   (DigiCam parity — the fit's native domain).
//
// u.isLinearSpace == 1: linear-light input. Un-linearize to gamma → apply
//   fitted curve → re-linearize. Two extra pow()s per channel, visual
//   parity with the perceptual branch; `lumaMean` is likewise converted
//   to gamma-space before plugging into the k/pivot formulas.
//
// Identity at contrast = 0 is exact in both branches: k → 0 collapses
// the cubic term; the pow wrapping is mathematically a no-op up to the
// 2.2-vs-true-sRGB approximation noise.

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

kernel void DCRContrastFilter(
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
    // gamma-space before plugging into the fit formulas, so k / pivot
    // hit the same tonal location regardless of color-space mode.
    float lumaMean = u.lumaMean;
    if (isLinear) {
        lumaMean = DCRSRGBLinearToGamma(lumaMean);
    }
    lumaMean = clamp(lumaMean, 0.05f, 0.95f);

    const float k     = (-0.356f * lumaMean + 2.289f) * contrast;
    const float pivot =  0.381f * lumaMean + 0.377f;

    for (int ch = 0; ch < 3; ch++) {
        float x = float(color[ch]);
        float x_gamma = isLinear ? DCRSRGBLinearToGamma(x) : x;
        float y = x_gamma + k * x_gamma * (1.0f - x_gamma) * (x_gamma - pivot);
        float y_clamped = clamp(y, 0.0f, 1.0f);
        color[ch] = half(isLinear ? DCRSRGBGammaToLinear(y_clamped) : y_clamped);
    }

    output.write(half4(color, original.a), gid);
}
