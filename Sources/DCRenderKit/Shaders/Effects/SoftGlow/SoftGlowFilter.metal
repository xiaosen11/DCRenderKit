//
//  SoftGlowFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

constant float3 kDCRSoftGlowLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

// Manual bilinear read — hardware `filter::linear` would require a
// sampler and normalized coords, and produces visible seams on small
// pyramid levels where integer coord → normalized mapping truncates.
inline half4 dcr_softGlowBilinear(
    texture2d<half, access::read> tex, float2 coord)
{
    int2 p = int2(floor(coord));
    float2 f = fract(coord);
    int maxX = int(tex.get_width()) - 1;
    int maxY = int(tex.get_height()) - 1;
    half4 c00 = tex.read(uint2(clamp(p.x,     0, maxX), clamp(p.y,     0, maxY)));
    half4 c10 = tex.read(uint2(clamp(p.x + 1, 0, maxX), clamp(p.y,     0, maxY)));
    half4 c01 = tex.read(uint2(clamp(p.x,     0, maxX), clamp(p.y + 1, 0, maxY)));
    half4 c11 = tex.read(uint2(clamp(p.x + 1, 0, maxX), clamp(p.y + 1, 0, maxY)));
    return mix(mix(c00, c10, half(f.x)), mix(c01, c11, half(f.x)), half(f.y));
}

// ── DCRSoftGlowBrightDownsample ──
//
// First level of the pyramid: 2×2 box average AND smoothstep highlight
// gating. smoothstep(t-0.1, t+0.1, luma) produces a 0.2-wide transition
// band around `threshold`, so dim regions output zero and only the
// brightest regions contribute to the bloom.

struct SoftGlowBrightUniforms {
    float threshold;   // smoothstep center
};

kernel void DCRSoftGlowBrightDownsample(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant SoftGlowBrightUniforms& u    [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    const float threshold = u.threshold;
    const uint inW = input.get_width();
    const uint inH = input.get_height();

    uint2 base = gid * 2;
    half4 s00 = input.read(min(base,                  uint2(inW - 1, inH - 1)));
    half4 s10 = input.read(min(base + uint2(1, 0),    uint2(inW - 1, inH - 1)));
    half4 s01 = input.read(min(base + uint2(0, 1),    uint2(inW - 1, inH - 1)));
    half4 s11 = input.read(min(base + uint2(1, 1),    uint2(inW - 1, inH - 1)));
    half4 avg = (s00 + s10 + s01 + s11) * 0.25h;

    half luma = dot(avg.rgb, half3(kDCRSoftGlowLumaRec709));
    half bright = smoothstep(half(threshold - 0.1f), half(threshold + 0.1f), luma);

    output.write(half4(avg.rgb * bright, avg.a), gid);
}

// ── DCRSoftGlowDownsample ──
//
// Plain 2×2 box average for mid-pyramid levels. No uniforms.

kernel void DCRSoftGlowDownsample(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    const uint inW = input.get_width();
    const uint inH = input.get_height();

    uint2 base = gid * 2;
    half4 s00 = input.read(min(base,                  uint2(inW - 1, inH - 1)));
    half4 s10 = input.read(min(base + uint2(1, 0),    uint2(inW - 1, inH - 1)));
    half4 s01 = input.read(min(base + uint2(0, 1),    uint2(inW - 1, inH - 1)));
    half4 s11 = input.read(min(base + uint2(1, 1),    uint2(inW - 1, inH - 1)));

    output.write((s00 + s10 + s01 + s11) * 0.25h, gid);
}

// ── DCRSoftGlowUpsample ──
//
// Upsample from lowerLevel with a 9-tap tent filter (1-2-1 / 2-4-2 /
// 1-2-1, weighted sum / 16). Optionally add the same-level current
// texture for pyramid accumulation (addCurrent > 0.5).
//
// Tap offset scales with the lower level's short side so the kernel
// produces a pixel-uniform circular tent regardless of aspect ratio.
// offset floor 0.5 ensures at least a half-texel spread on tiny
// pyramid levels where offsetRatio × shortSide would otherwise
// underflow.

struct SoftGlowUpsampleUniforms {
    float offsetRatio;   // fraction of min(lowerW, lowerH)
    float addCurrent;    // 1.0 = accumulate; 0.0 = skip
};

kernel void DCRSoftGlowUpsample(
    texture2d<half, access::write> output       [[texture(0)]],
    texture2d<half, access::read>  currentLevel [[texture(1)]],
    texture2d<half, access::read>  lowerLevel   [[texture(2)]],
    constant SoftGlowUpsampleUniforms& u        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    const uint lowerW = lowerLevel.get_width();
    const uint lowerH = lowerLevel.get_height();

    // Map output coord to lower-level coord (pixel centers).
    float2 center = (float2(gid) + 0.5f)
        * float2(float(lowerW) / float(outW), float(lowerH) / float(outH))
        - 0.5f;

    float offset = max(u.offsetRatio * float(min(lowerW, lowerH)), 0.5f);

    // 9-tap tent filter, weights sum to 16.
    half4 sum = half4(0.0h);
    sum += 1.0h * dcr_softGlowBilinear(lowerLevel, center + float2(-offset, -offset));
    sum += 2.0h * dcr_softGlowBilinear(lowerLevel, center + float2(      0, -offset));
    sum += 1.0h * dcr_softGlowBilinear(lowerLevel, center + float2( offset, -offset));
    sum += 2.0h * dcr_softGlowBilinear(lowerLevel, center + float2(-offset,       0));
    sum += 4.0h * dcr_softGlowBilinear(lowerLevel, center);
    sum += 2.0h * dcr_softGlowBilinear(lowerLevel, center + float2( offset,       0));
    sum += 1.0h * dcr_softGlowBilinear(lowerLevel, center + float2(-offset,  offset));
    sum += 2.0h * dcr_softGlowBilinear(lowerLevel, center + float2(      0,  offset));
    sum += 1.0h * dcr_softGlowBilinear(lowerLevel, center + float2( offset,  offset));
    sum /= 16.0h;

    if (u.addCurrent > 0.5f) {
        sum += currentLevel.read(gid);
    }

    output.write(sum, gid);
}

// ── DCRSoftGlowComposite ──
//
// Final Screen blend composite:
//   screened = 1 - (1 - src) · (1 - bloom)
//   result   = mix(src, screened, strength)
// Screen blend is softer than additive and naturally protects
// high-luminance regions from being clipped.

struct SoftGlowCompositeUniforms {
    float strength;   // 0 ... 0.35 (product-compressed)
};

kernel void DCRSoftGlowComposite(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    texture2d<half, access::read>  bloom  [[texture(2)]],
    constant SoftGlowCompositeUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    const half4 original = input.read(gid);
    const float strength = clamp(u.strength, 0.0f, 1.0f);

    if (strength < 0.001f) {
        output.write(original, gid);
        return;
    }

    half3 b = bloom.read(gid).rgb;
    half3 screened = 1.0h - (1.0h - original.rgb) * (1.0h - b);
    half3 result = mix(original.rgb, screened, half(strength));
    result = clamp(result, half3(0.0h), half3(1.0h));

    output.write(half4(result, original.a), gid);
}
