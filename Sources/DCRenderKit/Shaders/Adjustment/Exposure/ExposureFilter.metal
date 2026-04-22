//
//  ExposureFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// ── ExposureFilter ──
//
// Positive: linear-space Extended Reinhard tonemap
//   Reinhard et al., SIGGRAPH 2002 "Photographic Tone Reproduction".
//   Slider +1 maps to ≈ +4.25 EV; white point at 0.95 × gain.
//
// Negative: display-space A*pow(x,gamma) + B*x
//   A*x^gamma gives dark-region contrast, B*x is the linear shoulder term
//   that matches the consumer-app reference's S-curve shoulder lift.
//   A = 0.270, gamma = 3.49, B = 0.130 at slider = -1.
//
// Identity at exposure = 0 is exact (both branches gated by dead-zone).
//
// ## Color-space branching
//
// The positive branch runs Reinhard in linear-light space, which is the
// mathematically correct domain for radiometric tone-mapping. How it
// gets there depends on whether the SDK is configured as perceptual
// or linear:
//
//   u.isLinearSpace == 0 (perceptual mode):
//     The input texture stores sRGB-gamma encoded floats. The shader
//     explicitly linearizes with `pow(c, 2.2)`, tonemaps, then
//     re-encodes with `pow(c, 1/2.2)`. Output is gamma-encoded,
//     matching intermediate/drawable conventions for this mode.
//
//   u.isLinearSpace == 1 (linear mode):
//     The input texture is already linear (either loaded with
//     `.SRGB: true` so the GPU sampler auto-linearizes on read, or
//     produced by upstream filters that also operate on linear
//     values). The shader skips the explicit linearize/de-linearize
//     and tonemaps in-place. Output stays linear; the drawable
//     (`.bgra8Unorm_srgb`) will handle gamma encoding on final write.
//
// The negative branch's compound curve `A·x^γ + B·x` was fit against
// gamma-space reference exports from a consumer photo-editing app and is
// applied to whatever numeric distribution the input carries. In `.linear` mode
// the curve hits a different portion of the effective tonal range —
// the "feel" drifts vs. the DigiCam baseline, but the output stays
// finite and in-gamut. Refit is a future-work item tracked in the
// findings-and-plan doc.

struct ExposureUniforms {
    float exposure;       // -1.0 ... +1.0
    uint  isLinearSpace;  // 1 if the input is linear-light; 0 if gamma-encoded.
};

/// Approximate sRGB → linear. Cheap power-2.2 model; good enough for
/// the product fit that targets gamma-space JPEG reference exports. For
/// strict sRGB conformance the GPU's hardware sampler does a piecewise
/// curve — we use that path in `.linear` mode instead of doing it here.
inline float dcr_perceptualToLinearApprox(float c) {
    return pow(max(c, 0.0f), 2.2f);
}

/// Inverse of `dcr_perceptualToLinearApprox`. Same approximation.
inline float dcr_linearToPerceptualApprox(float c) {
    return pow(max(c, 0.0f), 1.0f / 2.2f);
}

kernel void DCRExposureFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant ExposureUniforms& u          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 original = input.read(gid);
    half3 color = original.rgb;

    // Product compression: slider ±1 maps to 70% of raw fit magnitude.
    const float exposure = clamp(u.exposure, -1.0f, 1.0f) * 0.7f;
    const bool isLinear = (u.isLinearSpace != 0u);

    if (exposure > 0.001f) {
        // Positive: Extended Reinhard in linear-light space.
        // FIXME(§8.6 Tier 2 + §8.5 B.2): EV_RANGE = 4.25 maps slider ±1
        // to ±4.25 EV. Inherited from Harbeth — narrower than Lightroom's
        // ±5 EV standard (see findings-and-plan.md §8.5 B.2 for
        // retain-vs-align decision). Origin of 4.25 lost with fitting
        // pipeline.
        //
        // `white * 0.95` is the Extended Reinhard white-point offset.
        // The 0.95 is empirical — keeps the mapped max slightly below
        // pure gain to avoid numerical saturation at peak. Origin of
        // 0.95 lost. Validation: findings-and-plan.md §8.6 Tier 2.
        const float EV_RANGE = 4.25f;
        const float gain = pow(2.0f, exposure * EV_RANGE);
        const float white = gain * 0.95f;
        const float white2 = white * white;

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float linear = isLinear ? max(c, 0.0f)
                                    : dcr_perceptualToLinearApprox(c);
            float gained = linear * gain;
            float mapped = gained * (1.0f + gained / white2) / (1.0f + gained);
            float clamped = clamp(mapped, 0.0f, 1.0f);
            color[ch] = half(isLinear ? clamped
                                      : dcr_linearToPerceptualApprox(clamped));
        }
    } else if (exposure < -0.001f) {
        // Negative: display-space compound curve.
        //   f(x) = A · x^γ + B · x
        // fit against gamma-space JPEG exports from a consumer photo-editing
        // app. Interpolated so identity at exposure = 0 (A=0, γ=1, B=1).
        // In .linear mode we
        // wrap with linearize/delinearize so the fit hits the same tonal
        // location — visual parity with perceptual mode.
        const float absExp = fabs(exposure);
        const float A = 0.270f * absExp;
        const float gamma = 1.0f + absExp * 2.49f;
        const float B = 1.0f - absExp * 0.870f;

        for (int ch = 0; ch < 3; ch++) {
            float c = float(color[ch]);
            float c_gamma = isLinear ? dcr_linearToPerceptualApprox(c) : c;
            float result = A * pow(max(c_gamma, 0.0f), gamma) + B * c_gamma;
            float clamped = clamp(result, 0.0f, 1.0f);
            color[ch] = half(isLinear ? dcr_perceptualToLinearApprox(clamped) : clamped);
        }
    }

    output.write(half4(color, original.a), gid);
}
