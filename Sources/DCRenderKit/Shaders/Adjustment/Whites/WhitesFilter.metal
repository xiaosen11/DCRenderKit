//
//  WhitesFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Rec.709 luma weights. Kept in sync with sibling filters that reduce
// RGB to luma in shader (BlacksFilter does not need it).
constant float3 kDCRLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

// ── WhitesFilter — weighted parabola positive, luma-ratio negative ──
//
// Positive branch:
//   y = x * (1 + k * x * (1-x)^b), per-channel, clamped to [0, 1]
//   k = k100 * t, b is LUT-interpolated against image mean luma.
//
// Negative branch:
//   y = luma * (1 + k_neg * luma^a * (1-luma)^b) on Rec.709 luma,
//   then rescale RGB by y / luma_safe.
//   Fixed params at slider = -1: k_neg = -0.1995, a = 1.4628, b = 0.2094.
//
// Identity at whites = 0 is exact.

struct WhitesUniforms {
    float whites;         // -1.0 ... +1.0
    float k100;           // positive-branch curvature (LUT)
    float b;              // positive-branch highlight concentration (LUT)
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

inline float dcr_whitesLinearToGamma(float c) {
    return pow(max(c, 0.0f), 1.0f / 2.2f);
}
inline float dcr_whitesGammaToLinear(float c) {
    return pow(max(c, 0.0f), 2.2f);
}

// ## Color-space branching
//
// Both the positive (per-channel weighted parabola) and negative (luma-
// ratio) branches were fit against gamma-space exports from a consumer
// photo-editing app. In `.linear` mode we wrap each RGB triplet:
// un-linearize to gamma → apply the existing formula → re-linearize.
// For the negative branch the luma is likewise computed on the gamma-
// space RGB so that the per-pixel ratio matches DigiCam parity.

kernel void DCRWhitesFilter(
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

    // Bring RGB to gamma space (no-op if already there).
    float3 rgb = float3(color);
    if (isLinear) {
        rgb.r = dcr_whitesLinearToGamma(rgb.r);
        rgb.g = dcr_whitesLinearToGamma(rgb.g);
        rgb.b = dcr_whitesLinearToGamma(rgb.b);
    }

    if (whites > 0.001f) {
        // Positive per-channel weighted parabola in gamma space.
        const float k100 = u.k100;
        const float b    = clamp(u.b, 0.5f, 3.0f);
        const float t    = whites;
        const float k    = k100 * t;

        for (int ch = 0; ch < 3; ch++) {
            float c = rgb[ch];
            float y = c * (1.0f + k * c * pow(max(1.0f - c, 1e-6f), b));
            rgb[ch] = clamp(y, 0.0f, 1.0f);
        }
    } else if (whites < -0.001f) {
        // Negative luma-ratio branch in gamma space.
        const float t = -whites;
        const float k_neg = -0.1995f * t;
        const float a_neg = 1.4628f;
        const float b_neg = 0.2094f;

        float luma = dot(rgb, kDCRLumaRec709);
        float luma_safe = max(luma, 1e-6f);
        float y = luma_safe
            * (1.0f + k_neg * pow(luma_safe, a_neg)
                            * pow(max(1.0f - luma_safe, 1e-6f), b_neg));
        float ratio = y / luma_safe;

        for (int ch = 0; ch < 3; ch++) {
            float c = rgb[ch] * ratio;
            rgb[ch] = clamp(c, 0.0f, 1.0f);
        }
    }

    // Re-linearize before write (no-op if we never left linear space).
    if (isLinear) {
        rgb.r = dcr_whitesGammaToLinear(rgb.r);
        rgb.g = dcr_whitesGammaToLinear(rgb.g);
        rgb.b = dcr_whitesGammaToLinear(rgb.b);
    }

    output.write(half4(half3(rgb), original.a), gid);
}
