//
//  GuidedFilter.metal
//  DCRenderKit
//
//  Shared Fast Guided Filter sub-kernels consumed by HighlightShadowFilter
//  and ClarityFilter. Each filter calls the same three kernels with its
//  own eps and radius parameters.
//
//  Reference: He, K. & Sun, J. (2015). "Fast Guided Filter"
//             arXiv:1505.00996
//

#include <metal_stdlib>
using namespace metal;

constant float3 kDCRGuidedLumaRec709 = float3(0.2126f, 0.7152f, 0.0722f);

// ── Self-guided filter pipeline (I == p) ──
//
//   a = var(I) / (var(I) + eps)
//   b = mean(I) * (1 - a)
//   output = mean(a) * I + mean(b)
//
// High-variance (edges):   a → 1, b → 0      → base ≈ I  (preserve)
// Low-variance (smooth):   a → 0, b → mean   → base ≈ local mean

// ════════════════════════════════════════════════════════════
// Step 1: 4× downsample + luma / luma²
// ════════════════════════════════════════════════════════════
// Output RG channels: R = mean luma of 4×4 block, G = mean luma² of 4×4 block
// The squared-mean is kept at low res so step 2 can compute variance in one pass.

kernel void DCRGuidedDownsampleLuma(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint outW = output.get_width();
    const uint outH = output.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    const int inW = int(input.get_width());
    const int inH = int(input.get_height());

    float sumL = 0.0f;
    float sumL2 = 0.0f;
    float count = 0.0f;

    for (int dy = 0; dy < 4; dy++) {
        for (int dx = 0; dx < 4; dx++) {
            int px = clamp(int(gid.x) * 4 + dx, 0, inW - 1);
            int py = clamp(int(gid.y) * 4 + dy, 0, inH - 1);
            float luma = dot(float3(input.read(uint2(px, py)).rgb), kDCRGuidedLumaRec709);
            sumL += luma;
            sumL2 += luma * luma;
            count += 1.0f;
        }
    }

    float meanL = sumL / count;
    float meanL2 = sumL2 / count;
    output.write(half4(half(meanL), half(meanL2), 0.0h, 1.0h), gid);
}

// ════════════════════════════════════════════════════════════
// Step 2: compute (a, b) coefficients at low resolution
// ════════════════════════════════════════════════════════════
// Per-pixel box filter over (2*rx+1) × (2*ry+1) neighbors of the
// luma/luma² texture. radiusX/Y are floats because consumers size
// them proportional to image short-side (integer truncation at high
// res drops box coverage unacceptably; keeping the computed float
// value lets the shader round only once).

struct DCRGuidedComputeABUniforms {
    float eps;       // variance regularization
    float radiusX;   // box filter radius (pixels, low-res domain)
    float radiusY;
};

kernel void DCRGuidedComputeAB(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  luma   [[texture(1)]],
    constant DCRGuidedComputeABUniforms& u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint width  = output.get_width();
    const uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) return;

    const float eps = u.eps;
    const int radiusX = max(int(round(u.radiusX)), 1);
    const int radiusY = max(int(round(u.radiusY)), 1);

    float sumL = 0.0f;
    float sumL2 = 0.0f;
    float count = 0.0f;

    for (int dy = -radiusY; dy <= radiusY; dy++) {
        for (int dx = -radiusX; dx <= radiusX; dx++) {
            int2 pos = int2(gid) + int2(dx, dy);
            pos.x = clamp(pos.x, 0, int(width) - 1);
            pos.y = clamp(pos.y, 0, int(height) - 1);
            half4 sample = luma.read(uint2(pos));
            sumL  += float(sample.r);
            sumL2 += float(sample.g);
            count += 1.0f;
        }
    }

    float meanL = sumL / count;
    float varL  = sumL2 / count - meanL * meanL;

    float a = varL / (varL + eps);
    float b = meanL * (1.0f - a);

    output.write(half4(half(a), half(b), 0.0h, 1.0h), gid);
}

// ════════════════════════════════════════════════════════════
// Step 3: box-filter smoothing of (a, b)
// ════════════════════════════════════════════════════════════
// Same box radius as Step 2. Smoothing the coefficients before
// upsampling is what gives guided filter its smooth, edge-preserving
// output — vs. upsampling raw (a, b) which would produce blocky tiling.

struct DCRGuidedSmoothABUniforms {
    float radiusX;
    float radiusY;
};

kernel void DCRGuidedSmoothAB(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  ab     [[texture(1)]],
    constant DCRGuidedSmoothABUniforms& u  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint width  = output.get_width();
    const uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) return;

    const int radiusX = max(int(round(u.radiusX)), 1);
    const int radiusY = max(int(round(u.radiusY)), 1);

    float sumA = 0.0f;
    float sumB = 0.0f;
    float count = 0.0f;

    for (int dy = -radiusY; dy <= radiusY; dy++) {
        for (int dx = -radiusX; dx <= radiusX; dx++) {
            int2 pos = int2(gid) + int2(dx, dy);
            pos.x = clamp(pos.x, 0, int(width) - 1);
            pos.y = clamp(pos.y, 0, int(height) - 1);
            half4 sample = ab.read(uint2(pos));
            sumA += float(sample.r);
            sumB += float(sample.g);
            count += 1.0f;
        }
    }

    output.write(half4(half(sumA / count), half(sumB / count), 0.0h, 1.0h), gid);
}
