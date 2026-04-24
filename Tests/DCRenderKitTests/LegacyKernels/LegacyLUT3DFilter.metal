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
    float intensity;      // 0 ... 1
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

// ## Color-space branching
//
// `.cube` files — the universal film-emulation exchange format — are
// defined as functions of **gamma-encoded** input RGB. The cube values
// themselves are the gamma-encoded outputs the colorist intended. The
// whole mapping lives entirely in display (perceptual) space.
//
// In `.linear` mode our inputs are linear-light floats. Looking them up
// in a gamma-space cube reads from an arbitrary, nonsense table location.
// The fix is the same gamma-wrap pattern used by the fitted tone filters:
// un-linearize → run the cube sample → re-linearize the output → mix.
//
// The `mix(src, lut, intensity)` still operates on the original input
// space (linear in `.linear` mode, gamma in `.perceptual` mode), which is
// the correct domain for the intensity blend. In `.linear` mode we
// re-linearize `lutColor` before mixing so both ends of the mix live in
// the same space.

kernel void DCRLegacyLUT3DFilter(
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
    const bool isLinear = (u.isLinearSpace != 0u);

    // Coords used to index the cube must be in gamma space (the cube's
    // native domain). In linear mode we un-linearize first.
    float3 rgbForLUT = clamp(float3(inColor.rgb), 0.0f, 1.0f);
    if (isLinear) {
        rgbForLUT.r = DCRSRGBLinearToGamma(rgbForLUT.r);
        rgbForLUT.g = DCRSRGBLinearToGamma(rgbForLUT.g);
        rgbForLUT.b = DCRSRGBLinearToGamma(rgbForLUT.b);
    }

    float4 lutColor = dcr_sampleLUT3D(lut, rgbForLUT);

    // The LUT output is in gamma space. In linear mode we re-linearize
    // before mixing with the linear input.
    if (isLinear) {
        lutColor.r = DCRSRGBGammaToLinear(lutColor.r);
        lutColor.g = DCRSRGBGammaToLinear(lutColor.g);
        lutColor.b = DCRSRGBGammaToLinear(lutColor.b);
    }

    const float mixFactor = clamp(u.intensity, 0.0f, 1.0f);
    const half3 result = mix(inColor.rgb, half3(lutColor.rgb), half(mixFactor));

    const half3 dithered = dcr_triangularDither(gid, result);

    output.write(half4(dithered, inColor.a), gid);
}
