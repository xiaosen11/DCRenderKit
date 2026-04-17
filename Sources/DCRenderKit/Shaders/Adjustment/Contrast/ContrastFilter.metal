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
// Fit against Lightroom ±100 exports across 3 scenes
// (bridge / castle / tower, mean luma 0.29 / 0.40 / 0.60). Joint
// cross-scene average MSE = 52.1 (≈ 7.2 levels / 2.8%).
//
// Identity at contrast = 0 is exact: k → 0 collapses the cubic term.

struct ContrastUniforms {
    float contrast;   // -1.0 ... +1.0
    float lumaMean;   //  0   ...  1
};

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
    const float lumaMean = clamp(u.lumaMean, 0.05f, 0.95f);

    const float k     = (-0.356f * lumaMean + 2.289f) * contrast;
    const float pivot =  0.381f * lumaMean + 0.377f;

    for (int ch = 0; ch < 3; ch++) {
        float x = float(color[ch]);
        float y = x + k * x * (1.0f - x) * (x - pivot);
        color[ch] = half(clamp(y, 0.0f, 1.0f));
    }

    output.write(half4(color, original.a), gid);
}
