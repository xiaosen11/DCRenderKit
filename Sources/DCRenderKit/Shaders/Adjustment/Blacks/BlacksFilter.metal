//
//  BlacksFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── BlacksFilter — shadow-concentrated multiplicative curve ──
//
// Model: y = x * (1 + k * (1-x)^a)
//   Positive: k =  0.6312 * t, a = 2.1857 (lift shadows)
//   Negative: k = -1.5515 * t, a = 2.3236 (crush shadows)
// Cross-scene fit spread on k: 4%, on a: 1% → fixed parameters. Fitted in
// gamma (sRGB) space against ±100 exports from a consumer photo-editing
// app.
//
// ## Color-space branching (u.isLinearSpace)
//
//   0 → gamma input, apply curve directly (DigiCam parity).
//   1 → linear input; un-linearize to gamma → apply fitted curve →
//       re-linearize. Visual parity with the perceptual branch at the
//       cost of two extra pow()s per channel.
//
// Identity at blacks = 0 is exact in both branches.

struct BlacksUniforms {
    float blacks;         // -1.0 ... +1.0
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// IEC 61966-2-1 piecewise sRGB curves (§8.1 A.1). See ContrastFilter.metal
// for rationale — this is the per-filter copy of the same formulas.
inline float dcr_blacksLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}
inline float dcr_blacksGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

kernel void DCRBlacksFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant BlacksUniforms& u            [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 original = input.read(gid);
    half3 color = original.rgb;

    const float blacks = clamp(u.blacks, -1.0f, 1.0f);
    const bool isLinear = (u.isLinearSpace != 0u);

    float k = 0.0f;
    float a = 1.0f;

    if (blacks > 0.001f) {
        k = 0.6312f * blacks;
        a = 2.1857f;
    } else if (blacks < -0.001f) {
        k = -1.5515f * (-blacks);
        a = 2.3236f;
    } else {
        output.write(original, gid);
        return;
    }

    for (int ch = 0; ch < 3; ch++) {
        float c = float(color[ch]);
        float c_gamma = isLinear ? dcr_blacksLinearToGamma(c) : c;
        float y = c_gamma * (1.0f + k * pow(max(1.0f - c_gamma, 1e-6f), a));
        float y_clamped = clamp(y, 0.0f, 1.0f);
        color[ch] = half(isLinear ? dcr_blacksGammaToLinear(y_clamped) : y_clamped);
    }

    output.write(half4(color, original.a), gid);
}
