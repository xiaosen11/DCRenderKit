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
// Cross-scene fit spread on k: 4%, on a: 1% → fixed parameters.
//
// Identity at blacks = 0 is exact.

struct BlacksUniforms {
    float blacks;   // -1.0 ... +1.0
};

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
        float y = c * (1.0f + k * pow(max(1.0f - c, 1e-6f), a));
        color[ch] = half(clamp(y, 0.0f, 1.0f));
    }

    output.write(half4(color, original.a), gid);
}
