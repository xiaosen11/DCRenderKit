//
//  VibranceFilter.metal
//  DCRenderKit
//
//  Adobe-semantic Vibrance: perceptually-selective chroma boost in
//  OKLCh that protects already-saturated pixels AND warm skin hues.
//  Replaces the GPUImage-lineage `(max - mean) × -3·vib` kernel that
//  shipped prior to #14.
//
//  Contract: docs/contracts/vibrance.md (§8.2 A+.4)
//  Space: OKLab (Ottosson 2020 — https://bottosson.github.io/posts/oklab/)
//

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════
// MIRROR: Foundation/OKLab.metal
// ═══════════════════════════════════════════════════════════════════
// ShaderLibrary compiles each .metal file into its own MTLLibrary
// (see ShaderLibrary.swift:236), so function symbols do not cross
// translation-unit boundaries. Canonical copy of these helpers
// lives in Foundation/OKLab.metal together with a test-only kernel
// suite. Edit one copy → edit every mirror. Grep:
//
//     // MIRROR: Foundation/OKLab.metal

static inline float3 DCRLinearSRGBToOKLab(float3 rgb) {
    const float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
    const float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
    const float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

    const float l_ = sign(l) * pow(abs(l), 1.0f / 3.0f);
    const float m_ = sign(m) * pow(abs(m), 1.0f / 3.0f);
    const float s_ = sign(s) * pow(abs(s), 1.0f / 3.0f);

    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
    );
}

static inline float3 DCROKLabToLinearSRGB(float3 lab) {
    const float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    const float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    const float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

    const float l = l_ * l_ * l_;
    const float m = m_ * m_ * m_;
    const float s = s_ * s_ * s_;

    return float3(
         4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

static inline float3 DCROKLabToOKLCh(float3 lab) {
    const float C = length(lab.yz);
    // Mirror of production atan2(0,0) NaN guard.
    const float h = (C < (1.0f / 4096.0f)) ? 0.0f : atan2(lab.z, lab.y);
    return float3(lab.x, C, h);
}

static inline float3 DCROKLChToOKLab(float3 lch) {
    const float a = lch.y * cos(lch.z);
    const float b = lch.y * sin(lch.z);
    return float3(lch.x, a, b);
}

constant float kDCROKLabGamutMargin = 1.0f / 4096.0f;

static inline bool DCROKLabIsInGamut(float3 rgb) {
    return all(rgb >= -kDCROKLabGamutMargin)
        && all(rgb <= 1.0f + kDCROKLabGamutMargin);
}

static inline float3 DCROKLChGamutClamp(float3 lch) {
    const float3 rgb0 = DCROKLabToLinearSRGB(DCROKLChToOKLab(lch));
    if (DCROKLabIsInGamut(rgb0)) {
        return lch;
    }
    float C_lo = 0.0f;
    float C_hi = lch.y;
    for (int i = 0; i < 10; i++) {
        const float C_mid = 0.5f * (C_lo + C_hi);
        const float3 rgb = DCROKLabToLinearSRGB(DCROKLChToOKLab(float3(lch.x, C_mid, lch.z)));
        if (DCROKLabIsInGamut(rgb)) {
            C_lo = C_mid;
        } else {
            C_hi = C_mid;
        }
    }
    return float3(lch.x, C_lo, lch.z);
}

// ═══════════════════════════════════════════════════════════════════
// Vibrance-specific constants
// ═══════════════════════════════════════════════════════════════════
// Low-saturation boost curve (smoothstep from full-weight to zero):
// - C < C_LOW_BOOST:   w_lowsat = 1 (full boost)
// - C > C_HIGH_BOOST:  w_lowsat = 0 (no boost — already saturated)
//
// Range chosen against OKLCh C of sRGB primaries (C_red ≈ 0.26,
// C_green ≈ 0.30, C_blue ≈ 0.31, ColorChecker skin patches ≈ 0.05–0.08).
// C_LOW_BOOST = 0.08 catches near-grayscale mid-chroma pixels; C_HIGH
// = 0.25 puts saturated primaries in the no-boost band.
constant float kDCRVibranceCLow  = 0.08f;
constant float kDCRVibranceCHigh = 0.25f;

// Skin hue protection (rads, OKLCh hue axis):
// - Centre ≈ 0.785 rad ≈ 45° — empirically matches ColorChecker Light
//   Skin (h ≈ 44.9°) and Dark Skin (h ≈ 46.7°) OKLCh hue, and aligns
//   with the cross-cultural preferred skin hue ≈ 49° reported in
//   CIELAB (IS&T 2020, "Preferred skin reproduction centres").
// - Half-width 0.436 rad ≈ 25° — covers the observed CIELAB skin hue
//   range 25°–80° mapped approximately to OKLCh. Smoothstep band has
//   inner edge at 70 % of the half-width (0.306 rad ≈ 17.5°) and outer
//   edge at 130 % (0.567 rad ≈ 32.5°) for a softened gate.
constant float kDCRVibranceSkinHueCenter     = 0.785398163f;   // π/4
constant float kDCRVibranceSkinHueInnerEdge  = 0.305432619f;   // 70 % of 25°
constant float kDCRVibranceSkinHueOuterEdge  = 0.566502879f;   // 130 % of 25°

// ═══════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════

/// Signed angular difference wrapped into `[-π, π]`, then absolute value.
float DCRVibranceAbsAngularDiff(float h1, float h2) {
    float d = h1 - h2;
    if (d >  M_PI_F) d -= 2.0f * M_PI_F;
    if (d < -M_PI_F) d += 2.0f * M_PI_F;
    return abs(d);
}

/// Skin gate: 1 near skin hue, 0 away, smoothstep transition.
float DCRVibranceSkinHueGate(float h) {
    const float delta = DCRVibranceAbsAngularDiff(h, kDCRVibranceSkinHueCenter);
    return 1.0f - smoothstep(kDCRVibranceSkinHueInnerEdge, kDCRVibranceSkinHueOuterEdge, delta);
}

// ═══════════════════════════════════════════════════════════════════
// Vibrance kernel
// ═══════════════════════════════════════════════════════════════════

struct VibranceUniforms {
    float vibrance;
};

kernel void DCRLegacyVibranceFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant VibranceUniforms& u          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 c = input.read(gid);
    const float vib = clamp(u.vibrance, -1.0f, 1.0f);

    // linear sRGB → OKLCh
    const float3 lab = DCRLinearSRGBToOKLab(float3(c.rgb));
    float3 lch = DCROKLabToOKLCh(lab);

    // Selective weights.
    const float w_lowsat = 1.0f - smoothstep(kDCRVibranceCLow, kDCRVibranceCHigh, lch.y);
    const float w_skin   = 1.0f - DCRVibranceSkinHueGate(lch.z);

    // Adobe-style selective boost: low-C + non-skin pixels see the
    // full slider effect; high-C or skin-hue pixels are protected.
    // Identity when vib = 0 (boost factor = 1).
    lch.y = lch.y * (1.0f + vib * w_lowsat * w_skin);

    // Preserve L and h; reduce C only if the boost pushed it past the
    // gamut boundary. Negative boosts (desaturation) never exceed the
    // boundary.
    lch = DCROKLChGamutClamp(lch);

    // OKLCh → linear sRGB
    const float3 lab_out = DCROKLChToOKLab(lch);
    const float3 rgb     = DCROKLabToLinearSRGB(lab_out);

    output.write(half4(half3(rgb), c.a), gid);
}
