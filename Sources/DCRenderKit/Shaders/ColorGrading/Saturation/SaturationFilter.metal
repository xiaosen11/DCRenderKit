//
//  SaturationFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Rec.709 luma coefficients. Matches Poynton / Core Image / Harbeth.
constant half3 kDCRSaturationLuma = half3(0.2125h, 0.7154h, 0.0721h);

struct SaturationUniforms {
    float saturation;
};

kernel void DCRSaturationFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant SaturationUniforms& u        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 c = input.read(gid);
    const half luma = dot(c.rgb, kDCRSaturationLuma);
    const half s = half(clamp(u.saturation, 0.0f, 2.0f));
    const half3 result = mix(half3(luma), c.rgb, s);
    output.write(half4(result, c.a), gid);
}
