//
//  CCDFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

constant float3 kDCRCCDLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

inline half dcr_ccdSoftLight(half base, half blend) {
    return base + (2.0h * blend - 1.0h) * base * (1.0h - base);
}

struct CCDUniforms {
    float strength;
    float density;
    float caAmount;
    float sharpAmount;
    float grainSize;
    float saturation;
    float sharpStep;
    float caMaxOffset;
};

// ── CCD sensor emulation — compound single-kernel effect ──
//
// Order matters: CA first (color fringing happens on raw sensor), then
// saturation (pre-noise so grain doesn't get saturated), then digital
// noise (sensor noise floor), then luma-channel sharpening sampled from
// original (so noise and CA edges aren't re-hardened), then strength mix.
//
// Step-ordering provenance (§8.1 A.4 verified 2026-04-22, fetched URL):
//
// The "CA → saturation → noise → sharpen" ordering is an **artistic look
// choice**, not a faithful reproduction of a real CCD/CMOS signal chain.
// Confirmed by comparing against openISP reference implementation at
// https://github.com/cruxopen/openISP whose documented ISP pipeline is:
//
//   Bayer:  DPC → BLC → LSC → Anti-aliasing NR → AWB → Bayer-NR
//   RGB:    Demosaic → Gamma → CCM → ColorSpaceConversion
//   YUV:    Luma/Chroma NR → Edge Enhancement → False-color → Hue/Sat
//
// Real ISPs:
//   - **Correct** chromatic aberration at lens/optical level (pre-sensor),
//     not as a mid-pipeline mutation — DCRenderKit instead **adds** CA
//     as an aesthetic "vintage" signature
//   - Apply noise **reduction** at two stages (Bayer + YUV) — DCRenderKit
//     **adds** synthetic grain as a "CCD sensor readout" aesthetic
//   - Place saturation/hue at the very **end** of YUV processing —
//     DCRenderKit puts saturation early (before noise injection) so the
//     grain doesn't get saturation-boosted
//   - Edge Enhancement (sharpening) happens **before** saturation in YUV,
//     not after — DCRenderKit reverses this to keep grain from being
//     re-sharpened
//
// Conclusion: the "CA → sat → noise → sharp" order is a coherent
// **aesthetic narrative** ("lens aberration → color look → sensor
// grain → post-processing polish") but it is NOT a sensor-physical
// simulation. The filter name "CCD" refers to the vintage-camera look,
// not to a simulation of CCD sensor physics. All downstream documents
// and SwiftDoc should describe this as an artistic effect, not a
// sensor model.
//
// Sources (fetched 2026-04-22):
// - github.com/cruxopen/openISP — documented open-source ISP pipeline
// - (§8.4 Audit.4 TODO: cross-reference VSCO / RNI / similar film-sim
//   app technical disclosures when available; none publicly documented
//   at time of verification)

// Body templated on `Tap` so codegen can substitute either
// `DCRRawSourceTap` (default) or a `KernelInlining`-generated
// fused tap that pre-applies an upstream pixelLocal body to each
// sample. Tap.read(int2) handles bounds clamping internally.
//
// @dcr:body-begin DCRCCDBody
template <typename Tap>
inline half3 DCRCCDBody(
    half3 rgbIn,
    constant CCDUniforms& u,
    uint2 gid,
    Tap src
) {
    const float strength    = clamp(u.strength, 0.0f, 1.0f);
    const float density     = clamp(u.density, 0.0f, 1.0f);
    const float caAmount    = clamp(u.caAmount, 0.0f, 1.0f);
    const float sharpAmount = clamp(u.sharpAmount, 0.0f, 1.0f);
    const float grainSize   = max(u.grainSize, 1.0f);
    const float saturation  = u.saturation;                    // 1.0 .. 1.3
    const int   sharpStep   = max(int(round(u.sharpStep)), 1);
    const float caMaxOffset = u.caMaxOffset;

    const int2 pos = int2(gid);

    // 1. Chromatic aberration: horizontal R/B offset.
    half4 color = half4(rgbIn, 1.0h);
    if (caAmount > 0.001f) {
        float caPx = caAmount * caMaxOffset;
        int2 posR = pos + int2(int(-round(caPx)), 0);
        int2 posB = pos + int2(int( round(caPx)), 0);
        color.r = src.read(posR).r;
        color.b = src.read(posB).b;
    }

    // 2. Saturation boost: Rec.709 luma anchor.
    if (saturation > 1.001f) {
        half luma = dot(color.rgb, half3(kDCRCCDLumaRec709));
        color.rgb = luma + (color.rgb - luma) * half(saturation);
        color.rgb = clamp(color.rgb, half3(0.0h), half3(1.0h));
    }

    // 3. Digital noise: block-quantized sin-trick, chromaticity = 0.6.
    if (density > 0.001f) {
        float2 grainPos = floor(float2(gid) / grainSize);
        // Tap.read() clamps out-of-range coords to the texture extent.
        int2 blockCenter = int2(grainPos * grainSize + grainSize * 0.5f);
        float luma = dot(float3(src.read(blockCenter).rgb), float3(0.299f, 0.587f, 0.114f));

        float nR = fract(sin(dot(grainPos, float2(12.9898f, 78.233f)) + luma * 43.0f) * 43758.5453f) * 2.0f - 1.0f;
        float exponent = mix(2.0f, 0.5f, density);
        nR = sign(nR) * pow(abs(nR), exponent);

        half3 blend = half3(0.5h + half(nR) * half(density) * 0.144h);

        float nG = fract(sin(dot(grainPos, float2(93.9898f, 67.345f)) + luma * 37.0f) * 43758.5453f) * 2.0f - 1.0f;
        float nB = fract(sin(dot(grainPos, float2(54.2781f, 31.917f)) + luma * 53.0f) * 43758.5453f) * 2.0f - 1.0f;
        nG = sign(nG) * pow(abs(nG), exponent);
        nB = sign(nB) * pow(abs(nB), exponent);
        blend.g = 0.5h + mix(half(nR), half(nG), 0.6h) * half(density) * 0.144h;
        blend.b = 0.5h + mix(half(nR), half(nB), 0.6h) * half(density) * 0.144h;

        color.r = dcr_ccdSoftLight(color.r, blend.r);
        color.g = dcr_ccdSoftLight(color.g, blend.g);
        color.b = dcr_ccdSoftLight(color.b, blend.b);
    }

    // 4. Luma-channel sharpening from ORIGINAL source.
    //    Sampling from src (not the mutated `color`) means grain and CA
    //    fringes don't get re-sharpened, and only luminance detail is
    //    lifted (keeps color fringing soft).
    if (sharpAmount > 0.001f) {
        const half3 kLumaH = half3(kDCRCCDLumaRec709);
        half4 origCenter = src.read(int2(gid));
        half4 left  = src.read(pos + int2(-sharpStep,  0));
        half4 right = src.read(pos + int2( sharpStep,  0));
        half4 top   = src.read(pos + int2( 0, -sharpStep));
        half4 bot   = src.read(pos + int2( 0,  sharpStep));
        // FIXME(§8.6 Tier 2): × 0.96 = 60% of SharpenFilter's × 1.6 product
        // compression (see SharpenFilter.swift's ×1.6 block). Derivation chain:
        // sharpAmount slider → SharpenFilter would apply × 1.6 → CCD uses
        // 60% of that = × 0.96. The 60% ratio itself is empirical
        // (hand-tuned balance of sharp vs CA vs noise). Transitively
        // depends on the SharpenFilter × 1.6 value.
        half s = half(sharpAmount * 0.96f);  // 60% of SharpenFilter amplitude

        half lumaC = dot(origCenter.rgb, kLumaH);
        half lumaL = dot(left.rgb,  kLumaH);
        half lumaR = dot(right.rgb, kLumaH);
        half lumaT = dot(top.rgb,   kLumaH);
        half lumaB = dot(bot.rgb,   kLumaH);
        half lumaDetail = (lumaC * 4.0h - lumaL - lumaR - lumaT - lumaB) * s;

        color.rgb = clamp(color.rgb + lumaDetail, half3(0.0h), half3(1.0h));
    }

    // 5. Final strength mix between pristine original (rgbIn) and processed.
    return mix(rgbIn, color.rgb, half(strength));
}
// @dcr:body-end

// Standalone `DCRCCDFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
