//
//  ExposureFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── ExposureFilter ──
//
// Positive: linear-space Extended Reinhard tonemap
//   Reinhard et al., SIGGRAPH 2002 "Photographic Tone Reproduction".
//   Slider +1 maps to ≈ +4.25 EV; white point at 0.95 × gain.
//
// Negative: display-space A*pow(x,gamma) + B*x
//   A*x^gamma gives dark-region contrast, B*x is the linear shoulder term
//   that matches Lightroom's ACR3 S-curve lift.
//   A = 0.270, gamma = 3.49, B = 0.130 at slider = -1.
//
// Identity at exposure = 0 is exact (both branches gated by dead-zone).

struct ExposureUniforms {
    float exposure;  // -1.0 ... +1.0
};

kernel void DCRExposureFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant ExposureUniforms& u          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 original = input.read(gid);
    half3 color = original.rgb;

    // Product compression: slider ±1 maps to 70% of raw fit magnitude.
    const float exposure = clamp(u.exposure, -1.0f, 1.0f) * 0.7f;

    if (exposure > 0.001f) {
        // Positive: linear-space Extended Reinhard.
        const float EV_RANGE = 4.25f;
        const float gain = pow(2.0f, exposure * EV_RANGE);
        const float white = gain * 0.95f;
        const float white2 = white * white;

        for (int ch = 0; ch < 3; ch++) {
            float linear = pow(max(float(color[ch]), 0.0f), 2.2f);
            float gained = linear * gain;
            float mapped = gained * (1.0f + gained / white2) / (1.0f + gained);
            color[ch] = half(pow(clamp(mapped, 0.0f, 1.0f), 1.0f / 2.2f));
        }
    } else if (exposure < -0.001f) {
        // Negative: display-space compound curve.
        //   f(x) = A * pow(x, gamma) + B * x
        // Interpolated so identity at exposure = 0 (A=0, gamma=1, B=1).
        const float absExp = fabs(exposure);
        const float A = 0.270f * absExp;
        const float gamma = 1.0f + absExp * 2.49f;
        const float B = 1.0f - absExp * 0.870f;

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float result = A * pow(max(c, 0.0f), gamma) + B * c;
            color[ch] = half(clamp(result, 0.0f, 1.0f));
        }
    }

    output.write(half4(color, original.a), gid);
}
