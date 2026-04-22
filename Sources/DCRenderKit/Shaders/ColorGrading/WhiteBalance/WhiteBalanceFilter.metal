//
//  WhiteBalanceFilter.metal
//  DCRenderKit
//

#include <metal_stdlib>
using namespace metal;

struct WhiteBalanceUniforms {
    float temperature;    // Kelvin, 4000 ... 8000
    float tint;           // -200 ... +200
    uint  isLinearSpace;  // 1 = linear input; 0 = gamma-encoded.
};

// HDR-safe Overlay blend: linear extrapolation outside [0, 1] instead
// of the standard piecewise formula's undefined behaviour. Matches
// Harbeth C7WhiteBalance for pixel parity.
inline half dcr_whiteBalanceOverlay(half v, half w) {
    if (v < 0.0h) {
        return v * (2.0h * w);
    } else if (v > 1.0h) {
        return 1.0h + 2.0h * (1.0h - w) * (v - 1.0h);
    } else if (v < 0.5h) {
        return 2.0h * v * w;
    } else {
        return 1.0h - 2.0h * (1.0h - v) * (1.0h - w);
    }
}

inline float dcr_whiteBalanceLinearToGamma(float c) {
    return pow(max(c, 0.0f), 1.0f / 2.2f);
}
inline float dcr_whiteBalanceGammaToLinear(float c) {
    return pow(max(c, 0.0f), 2.2f);
}

// ## Color-space branching
//
// The warm target (0.93, 0.54, 0) and tempCoef / tint fit were all done
// in gamma space against Lightroom JPEG references. YIQ is a linear
// transform of RGB, and its perceptual meaning depends on which space
// the RGB is in — mixing with the warm target in linear space produces
// visibly different whites-shift than in gamma space.
//
// u.isLinearSpace == 1: un-linearize to gamma → run the fit → re-linearize
// u.isLinearSpace == 0: direct gamma-space math (DigiCam parity)

kernel void DCRWhiteBalanceFilter(
    texture2d<half, access::write> output [[texture(0)]],
    texture2d<half, access::read>  input  [[texture(1)]],
    constant WhiteBalanceUniforms& u      [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    const half4 inColor = input.read(gid);
    const bool isLinear = (u.isLinearSpace != 0u);

    // Bring RGB to gamma space for the fit math.
    half3 rgb = inColor.rgb;
    if (isLinear) {
        rgb.r = half(dcr_whiteBalanceLinearToGamma(float(rgb.r)));
        rgb.g = half(dcr_whiteBalanceLinearToGamma(float(rgb.g)));
        rgb.b = half(dcr_whiteBalanceLinearToGamma(float(rgb.b)));
    }

    // RGB ↔ YIQ matrices (NTSC). Used here for tint (Q axis only).
    const half3x3 RGBtoYIQ = half3x3(
        half3(0.299h,  0.587h,  0.114h),
        half3(0.596h, -0.274h, -0.322h),
        half3(0.212h, -0.523h,  0.311h)
    );
    const half3x3 YIQtoRGB = half3x3(
        half3(1.000h,  0.956h,  0.621h),
        half3(1.000h, -0.272h, -0.647h),
        half3(1.000h, -1.105h,  1.702h)
    );

    // Tint on the Q axis only. Clamp keeps Q within the gamut the
    // matrices can represent; prevents runaway overshoot.
    const float tint = clamp(u.tint, -200.0f, 200.0f);
    half3 yiq = RGBtoYIQ * rgb;
    yiq.b = clamp(yiq.b + half(tint / 100.0f) * 0.5226h * 0.1h,
                  -0.5226h, 0.5226h);
    const half3 rgbTinted = YIQtoRGB * yiq;

    // Warm target and Overlay-blended version for temperature mixing.
    const half3 warm = half3(0.93h, 0.54h, 0.0h);
    half3 blended;
    for (int i = 0; i < 3; i++) {
        blended[i] = dcr_whiteBalanceOverlay(rgbTinted[i], warm[i]);
    }

    // Piecewise-linear Kelvin coefficient. Negative coefficient means
    // cool, positive means warm.
    const float tempK = clamp(u.temperature, 4000.0f, 8000.0f);
    float tempCoef;
    if (tempK < 5000.0f) {
        tempCoef = 0.0004f * (tempK - 5000.0f);
    } else {
        tempCoef = 0.00006f * (tempK - 5000.0f);
    }

    half3 mixed = mix(rgbTinted, blended, half(tempCoef));

    // Re-linearize before write (no-op in perceptual mode).
    if (isLinear) {
        mixed.r = half(dcr_whiteBalanceGammaToLinear(float(mixed.r)));
        mixed.g = half(dcr_whiteBalanceGammaToLinear(float(mixed.g)));
        mixed.b = half(dcr_whiteBalanceGammaToLinear(float(mixed.b)));
    }

    output.write(half4(mixed, inColor.a), gid);
}
