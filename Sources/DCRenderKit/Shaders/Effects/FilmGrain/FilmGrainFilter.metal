//
//  FilmGrainFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// Symmetric SoftLight. Derivation: Photoshop's SoftLight uses sqrt() for
// the lighten half and `base*(1-base)` for the darken half, which is not
// symmetric around 0.5 blend and biases mean brightness under noise. By
// perfectly compensating the lighten half, both branches collapse to a
// single closed form with zero bias:
//   result = base + (2·blend - 1) · base · (1 - base)
// Zero branches, zero sqrt, strictly symmetric.
inline half dcr_softLight(half base, half blend) {
    return base + (2.0h * blend - 1.0h) * base * (1.0h - base);
}

struct FilmGrainUniforms {
    float density;        // 0 ... 1
    float grainSize;      // pixels
    float roughness;      // 0 ... 1
    float chromaticity;   // 0 ... 1
};

kernel void DCRFilmGrainFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant FilmGrainUniforms& u         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const float density      = clamp(u.density, 0.0f, 1.0f);
    const float grainSize    = max(u.grainSize, 1.0f);
    const float roughness    = clamp(u.roughness, 0.0f, 1.0f);
    const float chromaticity = clamp(u.chromaticity, 0.0f, 1.0f);

    const half4 orig = input.read(gid);

    if (density < 0.001f) {
        output.write(orig, gid);
        return;
    }

    // Quantize grid coordinates so a grainSize×grainSize block shares
    // one noise sample. Preserves visible grain texture at all scales.
    float2 grainPos = floor(float2(gid) / grainSize);

    // Block-center pixel luma (shared across the block so luma-driven
    // randomness doesn't re-break the quantization).
    uint2 center = uint2(grainPos * grainSize + grainSize * 0.5f);
    center = min(center, uint2(output.get_width() - 1, output.get_height() - 1));
    float luma = dot(float3(input.read(center).rgb), float3(0.299f, 0.587f, 0.114f));

    // sin-trick noise in [-1, 1].
    float nR = fract(sin(dot(grainPos, float2(12.9898f, 78.233f)) + luma * 43.0f) * 43758.5453f) * 2.0f - 1.0f;

    // Roughness reshape: 0 → soft (concentrated near 0), 1 → coarse.
    float exponent = mix(2.0f, 0.5f, roughness);
    nR = sign(nR) * pow(abs(nR), exponent);

    // SoftLight blend value, `0.5` is neutral. `0.144` is the product-
    // tuned clamp so density=1 stays within perceptual comfort.
    half3 blend = half3(0.5h + half(nR) * half(density) * 0.144h);

    if (chromaticity > 0.001f) {
        float nG = fract(sin(dot(grainPos, float2(93.9898f, 67.345f)) + luma * 37.0f) * 43758.5453f) * 2.0f - 1.0f;
        float nB = fract(sin(dot(grainPos, float2(54.2781f, 31.917f)) + luma * 53.0f) * 43758.5453f) * 2.0f - 1.0f;
        nG = sign(nG) * pow(abs(nG), exponent);
        nB = sign(nB) * pow(abs(nB), exponent);
        blend.g = 0.5h + mix(half(nR), half(nG), half(chromaticity)) * half(density) * 0.144h;
        blend.b = 0.5h + mix(half(nR), half(nB), half(chromaticity)) * half(density) * 0.144h;
    }

    half3 result;
    result.r = dcr_softLight(orig.r, blend.r);
    result.g = dcr_softLight(orig.g, blend.g);
    result.b = dcr_softLight(orig.b, blend.b);

    output.write(half4(result, orig.a), gid);
}
