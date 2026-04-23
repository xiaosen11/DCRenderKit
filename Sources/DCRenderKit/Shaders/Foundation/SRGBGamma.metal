//
//  SRGBGamma.metal
//  DCRenderKit
//
//  Canonical source for the IEC 61966-2-1 piecewise sRGB transfer
//  function and its inverse. Provides `DCRSRGBLinearToGamma` and
//  `DCRSRGBGammaToLinear`, plus test-only kernels used by
//  `SRGBGammaConversionTests` to verify the implementation.
//
//  The helpers are NOT linkable across `.metal` files in this project —
//  `ShaderLibrary` compiles each `.metal` into its own `MTLLibrary` (see
//  `ShaderLibrary.compileMetalSourcesFromBundle`), so function symbols
//  do not cross translation-unit boundaries. Consumers therefore mirror
//  the helper block inline in their own shader source. Mirrors must
//  stay in sync with this file; grep for
//
//      // MIRROR: Foundation/SRGBGamma.metal
//
//  to find copies. A future Phase 2 tech-debt item: replace the
//  mirroring with a build-time Metal preprocessor that resolves
//  `#include` across the Shaders tree (tracked as informal follow-up
//  alongside the OKLab mirror system).
//
//  Reference: IEC 61966-2-1:1999, "Multimedia systems and equipment —
//             Colour measurement and management — Part 2-1: Colour
//             management — Default RGB colour space — sRGB"
//
//             Wikipedia overview (with the same formulas):
//             https://en.wikipedia.org/wiki/SRGB#Transfer_function_(%22gamma%22)
//
//  ## Why IEC 61966-2-1 piecewise (not pow(2.2) approximation)
//
//  The true sRGB transfer function is a two-piece curve: a linear
//  segment for small values (to keep the derivative finite at 0) and
//  a `pow(,1/2.4) * 1.055 - 0.055` segment elsewhere. The popular
//  `pow(,2.2)` approximation diverges from the true curve by up to
//  ~2 % at midtones — visible as colour cast when colour-space-aware
//  code mixes the two.
//
//  This canonical implementation matches what `MTKTextureLoader` with
//  `.SRGB: true` produces on-GPU via the hardware sampler. Software
//  round-trip is exact to ~0.01 % (the half-float precision floor of
//  the `rgba16Float` intermediate textures that carry colour values
//  between filters).
//
//  Precision note: all internal arithmetic uses `float` (not `half`).
//  The magic numbers 0.04045 / 12.92 / 0.0031308 / 1.055 / 2.4 are
//  IEC-specified constants and must not be rewritten in half.
//

#include <metal_stdlib>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════
// IEC 61966-2-1 piecewise sRGB transfer function
// ═══════════════════════════════════════════════════════════════════

/// Linear sRGB → gamma-encoded sRGB.
///
/// - For `c ≤ 0.0031308`: return `12.92 · c` (linear segment).
/// - For `c > 0.0031308`: return `1.055 · c^(1/2.4) − 0.055`.
///
/// Negative inputs are clamped to zero before application (the sRGB
/// curve is only defined for non-negative light). Out-of-gamut linear
/// values above 1.0 are preserved and may produce gamma-encoded
/// values above 1.0 in turn — the caller is responsible for any
/// clamping semantics.
inline float DCRSRGBLinearToGamma(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.0031308f ? 12.92f * cc
                             : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
}

/// Gamma-encoded sRGB → linear sRGB.
///
/// - For `c ≤ 0.04045`: return `c / 12.92` (linear segment).
/// - For `c > 0.04045`: return `((c + 0.055) / 1.055)^2.4`.
///
/// Negative inputs are clamped to zero before application. The two
/// thresholds (`0.04045` for gamma → linear and `0.0031308` for
/// linear → gamma) are the same point expressed in the two
/// coordinate systems: `12.92 · 0.0031308 ≈ 0.04045`.
inline float DCRSRGBGammaToLinear(float c) {
    float cc = max(c, 0.0f);
    return cc <= 0.04045f ? cc / 12.92f
                          : pow((cc + 0.055f) / 1.055f, 2.4f);
}

/// Vector overloads — component-wise application of the scalar forms.
inline float3 DCRSRGBLinearToGamma(float3 c) {
    return float3(
        DCRSRGBLinearToGamma(c.r),
        DCRSRGBLinearToGamma(c.g),
        DCRSRGBLinearToGamma(c.b)
    );
}

inline float3 DCRSRGBGammaToLinear(float3 c) {
    return float3(
        DCRSRGBGammaToLinear(c.r),
        DCRSRGBGammaToLinear(c.g),
        DCRSRGBGammaToLinear(c.b)
    );
}

// ═══════════════════════════════════════════════════════════════════
// Test-only kernels
// ═══════════════════════════════════════════════════════════════════
// Exercised from `SRGBGammaConversionTests.swift` in the tests
// target. Not part of the SDK public filter surface — these kernels
// exist solely to let Swift-layer tests pump inputs through the
// helpers and read back the results without a `FilterProtocol`
// wrapper for each helper.

/// rgb (linear) → gamma. Output channels hold the gamma-encoded
/// values; alpha passes through unchanged.
kernel void DCRSRGBLinearToGammaTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 gamma = DCRSRGBLinearToGamma(float3(c.rgb));
    output.write(half4(half3(gamma), c.a), gid);
}

/// rgb (gamma) → linear. Output channels hold the linear values;
/// alpha passes through unchanged.
kernel void DCRSRGBGammaToLinearTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 linearRGB = DCRSRGBGammaToLinear(float3(c.rgb));
    output.write(half4(half3(linearRGB), c.a), gid);
}

/// rgb → gamma → linear → rgb. Output should equal input (modulo
/// Float16 quantisation + pow() precision) for all non-negative
/// inputs. Lets Swift tests verify the round trip is the identity
/// within the expected tolerance.
kernel void DCRSRGBRoundTripTestKernel(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    const half4 c = input.read(gid);
    const float3 gamma = DCRSRGBLinearToGamma(float3(c.rgb));
    const float3 back  = DCRSRGBGammaToLinear(gamma);
    output.write(half4(half3(back), c.a), gid);
}
