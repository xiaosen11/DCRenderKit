//
//  SharpenFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// 4-neighbor Laplacian unsharp mask:
//   sharpened = center * (1 + 4s) - (left + right + top + bottom) * s
// Output clamped to [0, 1] to prevent halo artifacts in overflow regions.
// Center-pixel alpha is used (not neighbor alpha — that would introduce
// edge-of-texture alpha bleed).

inline half4 dcr_sharpenSafeRead(texture2d<half, access::read> tex, int2 pos) {
    uint2 clamped = uint2(
        clamp(pos.x, 0, int(tex.get_width()) - 1),
        clamp(pos.y, 0, int(tex.get_height()) - 1)
    );
    return tex.read(clamped);
}

struct SharpenUniforms {
    float amount;   // 0 ... 2
    float step;     // sampling step in pixels
};

kernel void DCRSharpenFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant SharpenUniforms& u           [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const float amount = clamp(u.amount, 0.0f, 2.0f);
    const int step     = max(int(round(u.step)), 1);
    const half4 center = input.read(gid);

    if (amount < 0.001f) {
        output.write(center, gid);
        return;
    }

    const int2 pos = int2(gid);
    half4 left  = dcr_sharpenSafeRead(input, pos + int2(-step,  0));
    half4 right = dcr_sharpenSafeRead(input, pos + int2( step,  0));
    half4 top   = dcr_sharpenSafeRead(input, pos + int2( 0, -step));
    half4 bot   = dcr_sharpenSafeRead(input, pos + int2( 0,  step));

    const half s = half(amount);
    const half centerMul = 1.0h + 4.0h * s;
    half3 sharpened = center.rgb * centerMul
        - (left.rgb + right.rgb + top.rgb + bot.rgb) * s;

    sharpened = clamp(sharpened, half3(0.0h), half3(1.0h));
    output.write(half4(sharpened, center.a), gid);
}
