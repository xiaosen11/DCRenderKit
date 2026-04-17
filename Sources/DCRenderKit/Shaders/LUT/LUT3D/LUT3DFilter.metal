//
//  LUT3DFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Software trilinear: read 8 neighbor texels explicitly, mix() seven times.
// Chosen over `filter::linear` because small LUTs (17³/25³) suffer from
// normalized-coord rounding with the hardware sampler, producing visible
// step artifacts at LUT corners.
inline float4 dcr_sampleLUT3D(texture3d<float, access::read> lut, float3 rgb) {
    const float size = float(lut.get_width());
    const float maxIdx = size - 1.0f;
    const float3 coord = rgb * maxIdx;

    const float3 lo = floor(coord);
    const float3 hi = min(lo + 1.0f, maxIdx);
    const float3 frac = coord - lo;

    const uint3 c0 = uint3(lo);
    const uint3 c1 = uint3(hi);

    const float4 v000 = lut.read(uint3(c0.x, c0.y, c0.z));
    const float4 v100 = lut.read(uint3(c1.x, c0.y, c0.z));
    const float4 v010 = lut.read(uint3(c0.x, c1.y, c0.z));
    const float4 v110 = lut.read(uint3(c1.x, c1.y, c0.z));
    const float4 v001 = lut.read(uint3(c0.x, c0.y, c1.z));
    const float4 v101 = lut.read(uint3(c1.x, c0.y, c1.z));
    const float4 v011 = lut.read(uint3(c0.x, c1.y, c1.z));
    const float4 v111 = lut.read(uint3(c1.x, c1.y, c1.z));

    const float4 m00 = mix(v000, v100, frac.x);
    const float4 m10 = mix(v010, v110, frac.x);
    const float4 m01 = mix(v001, v101, frac.x);
    const float4 m11 = mix(v011, v111, frac.x);

    const float4 m0 = mix(m00, m10, frac.y);
    const float4 m1 = mix(m01, m11, frac.y);

    return mix(m0, m1, frac.z);
}

// Triangular dither — sum of two independent uniforms hashed from pixel
// position. Amplitude ±1/255 (one 8-bit step), decorrelates quantization
// noise from the signal for banding-free downstream 8-bit writes.
inline half3 dcr_triangularDither(uint2 pos, half3 color) {
    float2 seed = float2(pos) * float2(12.9898f, 78.233f);
    float noise1 = fract(sin(dot(seed, float2(1.0f, 1.0f))) * 43758.5453f);
    float noise2 = fract(sin(dot(seed, float2(0.3183f, 0.7071f))) * 22578.1459f);
    float tri = noise1 - noise2;
    return color + half3(half(tri) * half(1.0f / 255.0f));
}

struct LUT3DUniforms {
    float intensity;   // 0 ... 1
};

kernel void DCRLUT3DFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    texture3d<float, access::read> lut    [[texture(2)]],
    constant LUT3DUniforms& u             [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 inColor = input.read(gid);
    const float3 rgb = clamp(float3(inColor.rgb), 0.0f, 1.0f);

    const float4 lutColor = dcr_sampleLUT3D(lut, rgb);

    const float mixFactor = clamp(u.intensity, 0.0f, 1.0f);
    const half3 result = mix(inColor.rgb, half3(lutColor.rgb), half(mixFactor));

    const half3 dithered = dcr_triangularDither(gid, result);

    output.write(half4(dithered, inColor.a), gid);
}
