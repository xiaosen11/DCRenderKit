//
//  FilmGrainFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── Hash choice (§8.4 Audit.6, 2026-04-23) ──
//
// The noise hash `fract(sin(dot(pos, (12.9898, 78.233))) · 43758.5453)`
// is the canonical "shadertoy sin-trick" — the exact same formula
// appears across real-time shader film-grain implementations:
//   - lettier.github.io/3d-game-shaders-for-beginners/film-grain.html
//   - shadertoy.com/view/3sGGRz ("Simple Film Grain Shader")
//   - mattdesl/glsl-film-grain (GitHub)
// It is the industry-standard hash for real-time GPU film-grain in
// the shader category. DCR uses it for the same reason: cheap,
// Float32-compatible, well-tested across the category.
//
// Trade-off vs realistic particle-based grain (Audit.6): IPOL 2017
// "Realistic Film Grain Rendering"
// (https://www.ipol.im/pub/art/2017/192/article_lr.pdf) uses stochastic
// silver-halide-crystal models per film stock (Kodak Portra cubic,
// Fuji sigma, etc.). That class of algorithm is an order of magnitude
// more expensive, offline-oriented, and NOT the right fit for the
// real-time camera-preview use case. DCR's category (real-time shader
// film grain) uses the hash approach universally, the sin-trick being
// its canonical realization.
//
// Numerically the sin-trick degrades past ~2¹⁶ argument magnitude due
// to sin precision falloff in Float32, producing visible diagonal /
// cross banding on large textures. Verified clean at 4K on 2026-04-22
// (§8.1 A.3):
//   - Test: FilmGrainPatternTests.test4KFilmGrainSinTrickRowColumnBanding
//   - Method: 4096×4096 uniform 0.5-gray patch, density=1, grainSize=1
//   - Row-mean stddev and column-mean stddev both within 1.1× the
//     i.i.d. noise baseline
//   - No periodic structure detectable by 1D first-moment analysis
//
// If future GPU architecture changes or new regression testing exposes
// banding at higher resolutions, replace with PCG (Jarzynski & Olano
// 2020) or Wyvill hash (GPU Pro 5). Keep the symmetric SoftLight blend
// pipeline (hash-independent).

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

// @dcr:body-begin DCRFilmGrainBody
inline half3 DCRFilmGrainBody(
    half3 rgbIn,
    constant FilmGrainUniforms& u,
    uint2 gid,
    texture2d<half, access::read> src
) {
    const float density      = clamp(u.density, 0.0f, 1.0f);
    const float grainSize    = max(u.grainSize, 1.0f);
    const float roughness    = clamp(u.roughness, 0.0f, 1.0f);
    const float chromaticity = clamp(u.chromaticity, 0.0f, 1.0f);

    if (density < 0.001f) {
        return rgbIn;
    }

    // Quantize grid coordinates so a grainSize×grainSize block shares
    // one noise sample. Preserves visible grain texture at all scales.
    float2 grainPos = floor(float2(gid) / grainSize);

    // Block-center pixel luma (shared across the block so luma-driven
    // randomness doesn't re-break the quantization).
    uint2 center = uint2(grainPos * grainSize + grainSize * 0.5f);
    center = min(center, uint2(src.get_width() - 1, src.get_height() - 1));
    float luma = dot(float3(src.read(center).rgb), float3(0.299f, 0.587f, 0.114f));

    // sin-trick noise in [-1, 1].
    float nR = fract(sin(dot(grainPos, float2(12.9898f, 78.233f)) + luma * 43.0f) * 43758.5453f) * 2.0f - 1.0f;

    // Roughness reshape: 0 → soft (concentrated near 0), 1 → coarse.
    float exponent = mix(2.0f, 0.5f, roughness);
    nR = sign(nR) * pow(abs(nR), exponent);

    // SoftLight blend value, `0.5` is neutral. `0.144` is the product-
    // tuned clamp so density=1 stays within perceptual comfort.
    //
    // FIXME(§8.6 Tier 2 archived): × 0.144 is an empirical hand-tuned
    // constant — not derived from any film-grain PSF measurement or a
    // standard grain model (AgX grain, darktable grain module, VSCO
    // reference, etc.). Same 0.144 appears in CCDFilter.metal noise
    // step (intentionally shared). Paired with the Tier 4 snapshot
    // regression baseline, this value is "locked by visual approval"
    // rather than derived from first principles.
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
    result.r = dcr_softLight(rgbIn.r, blend.r);
    result.g = dcr_softLight(rgbIn.g, blend.g);
    result.b = dcr_softLight(rgbIn.b, blend.b);

    return result;
}
// @dcr:body-end

kernel void DCRFilmGrainFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant FilmGrainUniforms& u         [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    const half4 orig = input.read(gid);
    output.write(half4(DCRFilmGrainBody(orig.rgb, u, gid, input), orig.a), gid);
}
