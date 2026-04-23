//
//  PortraitBlurFilter.metal
//  DCRenderKit
//
//  Two-pass Poisson-disc stochastic depth-of-field blur. Each pass
//  samples a 16-tap Poisson pattern; the second pass rotates its
//  pattern 90° relative to the first so the combined 32 sample
//  positions are uncorrelated. Effective standard deviation is
//  `σ_single · √2` — matches the Gaussian-of-two-Gaussians identity,
//  places the +100 slider in the Apple Portrait / Lightroom 50-100 px
//  range at 1080p / 4K without the residual banding 16-tap alone
//  shows at large radii.
//
//  References:
//    Mitchell, "Spectrally Optimal Sampling for Distribution Ray
//    Tracing" (SIGGRAPH 1991) — Poisson-disc sampling.
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

// ═══════════════════════════════════════════════════════════════════
// Poisson-disc sample patterns
// ═══════════════════════════════════════════════════════════════════
// Pass 1 uses the 16-tap pattern below. Pass 2 rotates it 90° CCW
// in-shader (`(x, y) → (-y, x)`). The rotated pattern never shares a
// sample position with the original: for any non-zero Poisson tap
// `(x, y)`, the rotated version `(-y, x)` is orthogonal to the
// original — the Poisson-disc minimum-distance property guarantees
// this to still lie in a gap between original samples at the same
// radius. That orthogonality is what makes the two-pass stack behave
// as a decorrelated 32-sample stochastic blur (vs. two correlated
// 16-sample convolutions whose variance only halves).
//
// Pre-computed constants match the DigiCam reference implementation
// for pixel parity with the baseline single-pass behaviour.
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

// Per-pass coefficient. Single pass peak radius is
// `strength · 0.030 · shortSide`; two-pass effective σ is
// `√2 · 0.030 · shortSide ≈ 0.0424 · shortSide`:
//   1080p → 46 px effective peak
//   4K    → 92 px effective peak
//
// Apple Portrait and Lightroom "Amount" controls typically land in
// the 50-100 px range on real photographs, so this coefficient puts
// the +100 slider at the low end of that range. If real-device
// feedback lands us in "still slightly too weak" territory, raise
// `kDCRPortraitBlurCoef` toward 0.035 (effective ~54 px @ 1080p,
// ~108 px @ 4K). If "too aggressive", drop toward 0.025 (effective
// 38 px @ 1080p, 76 px @ 4K).
constant float kDCRPortraitBlurCoef = 0.030f;

struct PortraitBlurUniforms {
    float strength;   // 0 ... 1 (slider / 100)
};

// ═══════════════════════════════════════════════════════════════════
// Pass 1: source + mask → blurred
// ═══════════════════════════════════════════════════════════════════
// Reads the original texture, applies a Gaussian-weighted 16-tap
// Poisson convolution using `kDCRPortraitPoissonDisc` directly, and
// mixes with the original by `blurAmount = (1 − mask) · strength`.

inline half4 dcr_portraitBlurSamplePattern(
    texture2d<half, access::read> input,
    int2 pos,
    float localRadius,
    bool rotate90)
{
    half3 accum = half3(0.0h);
    float totalWeight = 0.0f;

    for (int i = 0; i < 16; i++) {
        float2 base = kDCRPortraitPoissonDisc[i];
        // Rotate 90° CCW for pass 2: (x, y) → (-y, x).
        float2 tap = rotate90 ? float2(-base.y, base.x) : base;
        float2 offset = tap * localRadius;
        int2 samplePos = pos + int2(round(offset));
        half4 sampleColor = dcr_portraitBlurSafeRead(input, samplePos);
        // Gaussian-like radial weight (σ = 1/2 in unit-disc coords).
        float d = length(base);
        float weight = exp(-d * d * 2.0f);
        accum += sampleColor.rgb * half(weight);
        totalWeight += weight;
    }

    if (totalWeight > 0.001f) {
        accum /= half(totalWeight);
    }
    return half4(accum, 1.0h);
}

inline float dcr_portraitBlurMaskSample(
    texture2d<half, access::read> mask,
    uint2 gid,
    float inputW, float inputH)
{
    const float maskW = float(mask.get_width());
    const float maskH = float(mask.get_height());
    uint2 maskCoord = uint2(
        uint(float(gid.x) / inputW * maskW),
        uint(float(gid.y) / inputH * maskH)
    );
    maskCoord.x = min(maskCoord.x, uint(maskW - 1));
    maskCoord.y = min(maskCoord.y, uint(maskH - 1));
    return float(mask.read(maskCoord).r);
}

inline void dcr_portraitBlurEncode(
    texture2d<half, access::write> output,
    texture2d<half, access::read>  input,
    texture2d<half, access::read>  mask,
    constant PortraitBlurUniforms& u,
    uint2 gid,
    bool rotate90)
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const float blurStrength = clamp(u.strength, 0.0f, 1.0f);
    const half4 original = input.read(gid);

    if (blurStrength < 0.001f) {
        output.write(original, gid);
        return;
    }

    const float inputW = float(input.get_width());
    const float inputH = float(input.get_height());

    const float maskValue = dcr_portraitBlurMaskSample(mask, gid, inputW, inputH);
    // blurAmount: mask=1 → 0 (sharp subject); mask=0 → strength
    // (full blur). Mask-edge intermediates get a natural sharp→blur
    // fade without extra smoothstep logic.
    const float blurAmount = (1.0f - maskValue) * blurStrength;

    const float shortSide = min(inputW, inputH);
    const float maxBlurRadius = shortSide * kDCRPortraitBlurCoef;
    const float localRadius = blurAmount * maxBlurRadius;

    if (localRadius < 0.5f) {
        output.write(original, gid);
        return;
    }

    const half4 blurred = dcr_portraitBlurSamplePattern(
        input, int2(gid), localRadius, rotate90
    );
    half3 result = mix(original.rgb, blurred.rgb, half(blurAmount));
    output.write(half4(result, original.a), gid);
}

kernel void DCRPortraitBlurFilterPass1(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    texture2d<half, access::read>  mask   [[texture(2)]],
    constant PortraitBlurUniforms& u      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    dcr_portraitBlurEncode(output, input, mask, u, gid, /*rotate90:*/ false);
}

// ═══════════════════════════════════════════════════════════════════
// Pass 2: pass1 output + mask → final output
// ═══════════════════════════════════════════════════════════════════
// Identical sampling kernel to pass 1, but with the Poisson pattern
// rotated 90° CCW. Pass 2's `input` argument is pass 1's output
// texture (threaded by MultiPassExecutor); mask is the same external
// mask both passes receive from `PortraitBlurFilter.additionalInputs`.

kernel void DCRPortraitBlurFilterPass2(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    texture2d<half, access::read>  mask   [[texture(2)]],
    constant PortraitBlurUniforms& u      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    dcr_portraitBlurEncode(output, input, mask, u, gid, /*rotate90:*/ true);
}
