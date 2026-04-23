//
//  OKLab.metal
//  DCRenderKit
//
//  Canonical source for OKLab / OKLCh colour-space helpers. Defines the
//  forward / inverse transforms and a gamut clamp, plus a suite of
//  test-only kernels used by `OKLabConversionTests` to verify the
//  implementation.
//
//  The helpers are NOT linkable across `.metal` files in this project —
//  `ShaderLibrary` compiles each `.metal` into its own `MTLLibrary` (see
//  `ShaderLibrary.compileMetalSourcesFromBundle`), so function symbols
//  do not cross translation-unit boundaries. Consumers (#14 Vibrance,
//  #77 Saturation) therefore mirror the helper block inline in their
//  own shader source. Mirrors must stay in sync with this file; grep
//  for `// MIRROR: Foundation/OKLab.metal` to find copies.
//
//  A future Phase 2 tech-debt item: replace the mirroring with a
//  build-time Metal preprocessor that resolves `#include` across the
//  Shaders tree. Tracked as informal follow-up to #76.
//
//  Reference: Björn Ottosson (2020).
//             "A perceptual color space for image processing."
//             https://bottosson.github.io/posts/oklab/
//             Adopted by CSS Color Level 4/5 since 2021-12 (W3C).
//
//  Gamut clamp reference: Björn Ottosson (2021).
//             "Gamut clipping for Oklab."
//             https://bottosson.github.io/posts/gamutclipping/
//
//  Precision note: all internal arithmetic uses `float` (not `half`)
//  so that the 10-decimal-digit matrix coefficients do not accumulate
//  significant error through half-float rounding. Caller upcasts
//  `half3 → float3` at the boundary.
//

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════
// Linear sRGB ↔ OKLab
// ═══════════════════════════════════════════════════════════════════

/// Convert linear sRGB (D65) to OKLab.
///
/// Two matrix multiplications separated by a cube-root non-linearity.
/// See Ottosson (2020) §"Converting from linear sRGB".
float3 DCRLinearSRGBToOKLab(float3 rgb) {
    // M1: linear sRGB → LMS (long/medium/short cone responses).
    const float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
    const float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
    const float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

    // Cube root non-linearity. `sign(x) · |x|^(1/3)` handles negative
    // LMS values (outside sRGB gamut) without spawning NaN — the cube
    // root of a negative real is well-defined but `pow()` isn't.
    const float l_ = sign(l) * pow(abs(l), 1.0f / 3.0f);
    const float m_ = sign(m) * pow(abs(m), 1.0f / 3.0f);
    const float s_ = sign(s) * pow(abs(s), 1.0f / 3.0f);

    // M2: LMS' → OKLab.
    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,  // L
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,  // a
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_   // b
    );
}

/// Convert OKLab to linear sRGB (D65).
float3 DCROKLabToLinearSRGB(float3 lab) {
    // Inverse M2: OKLab → LMS'.
    const float l_ = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    const float m_ = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    const float s_ = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;

    // Cube: LMS' → LMS.
    const float l = l_ * l_ * l_;
    const float m = m_ * m_ * m_;
    const float s = s_ * s_ * s_;

    // Inverse M1: LMS → linear sRGB.
    return float3(
         4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

// ═══════════════════════════════════════════════════════════════════
// OKLab ↔ OKLCh (polar form)
// ═══════════════════════════════════════════════════════════════════

/// Convert OKLab (Cartesian) to OKLCh (cylindrical).
///
/// `L` is unchanged. `C = √(a² + b²)` is chroma (colourfulness at fixed
/// lightness). `h = atan2(b, a)` is hue in radians, range `(-π, π]`.
/// Callers that want `[0, 2π)` should add `2π` when `h < 0`.
float3 DCROKLabToOKLCh(float3 lab) {
    const float C = length(lab.yz);
    const float h = atan2(lab.z, lab.y);
    return float3(lab.x, C, h);
}

/// Convert OKLCh back to OKLab.
float3 DCROKLChToOKLab(float3 lch) {
    const float a = lch.y * cos(lch.z);
    const float b = lch.y * sin(lch.z);
    return float3(lch.x, a, b);
}

// ═══════════════════════════════════════════════════════════════════
// Gamut clamp
// ═══════════════════════════════════════════════════════════════════

/// Small margin absorbing float-rounding noise at the gamut boundary.
/// Chosen to be well below Float16 texture quantization (~1/1024).
constant float kDCROKLabGamutMargin = 1.0f / 4096.0f;

/// True if the linear-sRGB triple is within `[0, 1]³` (± margin).
bool DCROKLabIsInGamut(float3 rgb) {
    return all(rgb >= -kDCROKLabGamutMargin)
        && all(rgb <= 1.0f + kDCROKLabGamutMargin);
}

/// Clamp an OKLCh triple so that the corresponding linear sRGB is in
/// `[0, 1]³`. Preserves `L` and `h` exactly; reduces `C` toward 0 only
/// as much as needed.
///
/// Algorithm: binary search on C ∈ [0, input.C]. The anchor `(L, 0, h)`
/// — pure gray at the same lightness — is always in gamut for
/// L ∈ [0, 1], so the interval is non-empty and convergence is
/// guaranteed. 10 iterations resolve C to ~2⁻¹⁰ ≈ 1e-3, well below
/// Float16 texture precision.
///
/// Rationale for binary search (vs. Ottosson's analytical triangular
/// clamp): simpler code surface, no spline approximation lookup. The
/// analytical method is faster but requires maintaining a gamut boundary
/// LUT. Future-swap documented in the header comment at the top of this
/// file.
float3 DCROKLChGamutClamp(float3 lch) {
    // Fast path: already in gamut.
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
// Test-only kernels
// ═══════════════════════════════════════════════════════════════════
// Exercised from `OKLabConversionTests.swift` (Tests target). Not part
// of the SDK public filter surface — these kernels exist solely to let
// Swift-layer tests pump inputs through the helpers and read back the
// results without a `FilterProtocol` wrapper for each helper.
//
// All kernels accept rgba16Float input/output so negative OKLab values
// (a, b ∈ roughly [-0.5, 0.5]) and OKLCh h (radians in (-π, π]) survive
// the round trip intact.

/// rgb → OKLab → rgb. Output should equal input for all in-gamut
/// inputs (within Float16 quantization + matrix rounding).
kernel void DCROKLabRoundTripTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 lab = DCRLinearSRGBToOKLab(float3(c.rgb));
    const float3 rgb = DCROKLabToLinearSRGB(lab);
    output.write(half4(half3(rgb), c.a), gid);
}

/// rgb → OKLab → output channels verbatim (L=R, a=G, b=B). Alpha
/// passes through. Lets Swift tests read OKLab values directly.
kernel void DCROKLabExposeLabTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 lab = DCRLinearSRGBToOKLab(float3(c.rgb));
    output.write(half4(half3(lab), c.a), gid);
}

/// rgb → OKLab → OKLCh → output channels (L=R, C=G, h=B in radians).
kernel void DCROKLabExposeLChTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 lab = DCRLinearSRGBToOKLab(float3(c.rgb));
    const float3 lch = DCROKLabToOKLCh(lab);
    output.write(half4(half3(lch), c.a), gid);
}

/// Full chain: rgb → OKLab → OKLCh → gamut-clamp → OKLab → rgb. Output
/// is always in `[0, 1]³` (modulo the gamut margin). Used to stress the
/// clamp on intentionally out-of-gamut OKLCh inputs constructed by
/// amplifying chroma before the clamp.
///
/// The uniform `chromaMultiplier` lets tests push C past the gamut
/// boundary before clamp, verifying the clamp rescues the result.
struct DCROKLabGamutClampTestUniforms {
    float chromaMultiplier;
};

kernel void DCROKLabGamutClampTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant DCROKLabGamutClampTestUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 lab = DCRLinearSRGBToOKLab(float3(c.rgb));
    float3 lch = DCROKLabToOKLCh(lab);
    lch.y *= u.chromaMultiplier;
    const float3 lch_clamped = DCROKLChGamutClamp(lch);
    const float3 lab_clamped = DCROKLChToOKLab(lch_clamped);
    const float3 rgb = DCROKLabToLinearSRGB(lab_clamped);
    output.write(half4(half3(rgb), c.a), gid);
}
