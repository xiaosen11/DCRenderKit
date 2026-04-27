//
//  SharpenFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

// 4-neighbor Laplacian unsharp mask:
//   sharpened = center * (1 + 4s) - (left + right + top + bottom) * s
// Output clamped to [0, 1] to prevent halo artifacts in overflow regions.
// Center-pixel alpha is used (not neighbor alpha — that would introduce
// edge-of-texture alpha bleed).

struct SharpenUniforms {
    float amount;   // 0 ... 2
    float step;     // sampling step in pixels
};

// Body templated on `Tap` so codegen can substitute either
// `DCRRawSourceTap` (default) or a `KernelInlining`-generated
// fused tap that pre-applies an upstream pixelLocal body to each
// sample. Tap.read(int2) handles bounds clamping internally.
//
// @dcr:body-begin DCRSharpenBody
template <typename Tap>
inline half3 DCRSharpenBody(
    half3 rgbIn,
    constant SharpenUniforms& u,
    uint2 gid,
    Tap src
) {
    const float amount = clamp(u.amount, 0.0f, 2.0f);
    const int step     = max(int(round(u.step)), 1);

    if (amount < 0.001f) {
        return rgbIn;
    }

    const int2 pos = int2(gid);
    half4 left  = src.read(pos + int2(-step,  0));
    half4 right = src.read(pos + int2( step,  0));
    half4 top   = src.read(pos + int2( 0, -step));
    half4 bot   = src.read(pos + int2( 0,  step));

    const half s = half(amount);
    const half centerMul = 1.0h + 4.0h * s;
    half3 sharpened = rgbIn * centerMul
        - (left.rgb + right.rgb + top.rgb + bot.rgb) * s;

    return clamp(sharpened, half3(0.0h), half3(1.0h));
}
// @dcr:body-end

// Standalone `DCRSharpenFilter` kernel retired in Phase 5 step 5.5.
// Dispatch now flows through the runtime-compiled uber kernel —
// see docs/pipeline-compiler-design.md §4 and Tests/DCRenderKit
// Tests/LegacyKernels/ for the frozen parity copy.
