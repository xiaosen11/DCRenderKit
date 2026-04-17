//
//  PortraitBlurFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

inline half4 dcr_portraitBlurSafeRead(texture2d<half, access::read> tex, int2 pos) {
    uint2 clamped = uint2(
        clamp(pos.x, 0, int(tex.get_width()) - 1),
        clamp(pos.y, 0, int(tex.get_height()) - 1)
    );
    return tex.read(clamped);
}

// Poisson-disc sample pattern — 16 points inside the unit disc placed
// so no two are closer than the "minimum-distance" criterion. Produces
// visually smooth bokeh without the grid-aliased cross artefacts of
// regular grids at low sample counts. Pre-computed constants match
// the DigiCam reference implementation for pixel parity.
constant float2 kDCRPortraitPoissonDisc[] = {
    float2(-0.9423f, -0.3994f), float2( 0.9453f,  0.2937f),
    float2(-0.1768f, -0.9296f), float2( 0.2163f,  0.9686f),
    float2(-0.6603f,  0.6425f), float2( 0.6836f, -0.6692f),
    float2(-0.3563f, -0.1635f), float2( 0.3780f,  0.1455f),
    float2(-0.8297f,  0.0596f), float2( 0.8149f, -0.1135f),
    float2(-0.0699f, -0.5364f), float2( 0.0826f,  0.5272f),
    float2(-0.4973f,  0.3693f), float2( 0.4818f, -0.3905f),
    float2(-0.2315f,  0.8650f), float2( 0.2472f, -0.8777f),
};

struct PortraitBlurUniforms {
    float strength;   // 0 ... 0.5 (product-compressed)
};

kernel void DCRPortraitBlurFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    texture2d<half, access::read>  mask   [[texture(2)]],
    constant PortraitBlurUniforms& u      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const float blurStrength = clamp(u.strength, 0.0f, 1.0f);
    const half4 original = input.read(gid);

    if (blurStrength < 0.001f) {
        output.write(original, gid);
        return;
    }

    // Mask sampling with nearest-neighbour resolution mapping. Vision
    // sometimes returns masks at a different resolution than the input;
    // normalized coords let the shader tolerate either case.
    const float inputW = float(input.get_width());
    const float inputH = float(input.get_height());
    const float maskW  = float(mask.get_width());
    const float maskH  = float(mask.get_height());

    uint2 maskCoord = uint2(
        uint(float(gid.x) / inputW * maskW),
        uint(float(gid.y) / inputH * maskH)
    );
    maskCoord.x = min(maskCoord.x, uint(maskW - 1));
    maskCoord.y = min(maskCoord.y, uint(maskH - 1));
    const float maskValue = float(mask.read(maskCoord).r);

    // blurAmount: mask=1 → 0 (sharp subject), mask=0 → strength (full blur).
    // Mask-edge intermediate values get a natural fade without extra
    // smoothstep logic.
    const float blurAmount = (1.0f - maskValue) * blurStrength;

    // localRadius scales with shortSide — image-structure spatial param.
    // maxRadius = 0.025 × shortSide:
    //   1080p short side 1080 → 27 px peak
    //   4K short side 2160 → 54 px peak
    const float shortSide = min(inputW, inputH);
    const float maxBlurRadius = shortSide * 0.025f;
    const float localRadius = blurAmount * maxBlurRadius;

    if (localRadius < 0.5f) {
        output.write(original, gid);
        return;
    }

    // 16-tap Poisson-disc sum with Gaussian weight falloff.
    const int2 pos = int2(gid);
    half3 accum = half3(0.0h);
    float totalWeight = 0.0f;

    for (int i = 0; i < 16; i++) {
        float2 offset = kDCRPortraitPoissonDisc[i] * localRadius;
        int2 samplePos = pos + int2(round(offset));
        half4 sampleColor = dcr_portraitBlurSafeRead(input, samplePos);
        float d = length(kDCRPortraitPoissonDisc[i]);
        float weight = exp(-d * d * 2.0f);
        accum += sampleColor.rgb * half(weight);
        totalWeight += weight;
    }

    if (totalWeight > 0.001f) {
        accum /= half(totalWeight);
    }

    half3 result = mix(original.rgb, accum, half(blurAmount));
    output.write(half4(result, original.a), gid);
}

// Identity fallback: used when the caller constructs the filter without
// a mask. We still need a real kernel that writes to the destination so
// ComputeDispatcher's binding convention is satisfied end-to-end.
kernel void DCRPortraitBlurIdentity(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    output.write(input.read(gid), gid);
}
