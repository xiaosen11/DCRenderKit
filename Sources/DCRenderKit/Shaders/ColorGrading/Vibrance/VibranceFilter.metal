//
//  VibranceFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

struct VibranceUniforms {
    float vibrance;
};

kernel void DCRVibranceFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant VibranceUniforms& u          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 c = input.read(gid);

    // Saturation proxy: max channel minus mean of all channels.
    const half average = (c.r + c.g + c.b) / 3.0h;
    const half mx = max(c.r, max(c.g, c.b));
    const half amt = (mx - average) * half(-clamp(u.vibrance, -1.2f, 1.2f) * 3.0f);

    const half3 result = mix(c.rgb, half3(mx), amt);
    output.write(half4(result, c.a), gid);
}
