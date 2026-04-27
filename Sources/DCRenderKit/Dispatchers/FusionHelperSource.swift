//
//  FusionHelperSource.swift
//  DCRenderKit
//
//  Canonical Metal helper text injected into every uber kernel. Each
//  constant below is a hand-maintained MIRROR of its corresponding
//  `.metal` file — SwiftPM compiles every `.metal` into its own
//  `MTLLibrary`, so at uber-kernel build time the runtime-generated
//  source needs its own copy of any helper function / constant the
//  spliced body depends on.
//
//  Keeping this in Swift (rather than reading the `.metal` file at
//  runtime and extracting a marker block) means the compute backend
//  never performs file I/O for helpers — the strings are embedded at
//  SDK build time and copied into the generated uber-kernel source
//  verbatim.
//
//  Sync discipline: any edit to a Foundation/* helper function or a
//  filter's private constant/helper must land here in the matching
//  block. The Phase-3 legacy-parity tests (step 5) surface drift:
//  if a helper changes in one place and not the other, the uber
//  kernel's output diverges from the legacy kernel's output and
//  the parity test fails immediately.
//

import Foundation

@available(iOS 18.0, *)
internal enum FusionHelperSource {

    // MARK: - Canonical colour-space helpers

    /// MIRROR: `Foundation/SRGBGamma.metal`
    /// Canonical IEC 61966-2-1 piecewise sRGB transfer functions and
    /// their inverses. Every filter whose body references
    /// `DCRSRGBLinearToGamma` / `DCRSRGBGammaToLinear` (Exposure,
    /// Contrast, Blacks, Whites, WhiteBalance, LUT3D) has this block
    /// injected into its uber kernel.
    static let srgbGamma: String = """
    inline float DCRSRGBLinearToGamma(float c) {
        float cc = max(c, 0.0f);
        return cc <= 0.0031308f ? 12.92f * cc
                                 : 1.055f * pow(cc, 1.0f / 2.4f) - 0.055f;
    }
    inline float DCRSRGBGammaToLinear(float c) {
        float cc = max(c, 0.0f);
        return cc <= 0.04045f ? cc / 12.92f
                              : pow((cc + 0.055f) / 1.055f, 2.4f);
    }
    inline float3 DCRSRGBLinearToGamma(float3 c) {
        return float3(DCRSRGBLinearToGamma(c.r), DCRSRGBLinearToGamma(c.g), DCRSRGBLinearToGamma(c.b));
    }
    inline float3 DCRSRGBGammaToLinear(float3 c) {
        return float3(DCRSRGBGammaToLinear(c.r), DCRSRGBGammaToLinear(c.g), DCRSRGBGammaToLinear(c.b));
    }
    """

    /// MIRROR: `Foundation/OKLab.metal`
    /// Canonical OKLab / OKLCh helpers + gamut-margin constant.
    /// Required by Saturation / Vibrance bodies. The `static inline`
    /// qualifier mirrors the canonical source so dead-code
    /// elimination strips unused helpers per compilation unit.
    static let oklab: String = """
    constant float kDCROKLabGamutMargin = 1.0f / 4096.0f;

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
        // `atan2(0, 0)` returns NaN on some Apple Metal GPU
        // implementations even though IEEE 754 specifies 0. At C = 0
        // the hue is mathematically undefined and downstream
        // `OKLChToOKLab` rebuilds `(C·cos(h), C·sin(h))` — multiplying
        // NaN by 0 leaves NaN in IEEE 754, propagating through Sat /
        // Vib bodies as visible "脏黑斑" on neutral pixels. See
        // canonical OKLab.metal for the full diagnosis; this is a
        // mirror.
        const float h = (C < (1.0f / 4096.0f)) ? 0.0f : atan2(lab.z, lab.y);
        return float3(lab.x, C, h);
    }

    static inline float3 DCROKLChToOKLab(float3 lch) {
        const float a = lch.y * cos(lch.z);
        const float b = lch.y * sin(lch.z);
        return float3(lch.x, a, b);
    }

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
    """

    // MARK: - Filter-private helpers

    /// MIRROR: `Shaders/ColorGrading/WhiteBalance/WhiteBalanceFilter.metal`
    /// `dcr_whiteBalanceOverlay` — HDR-safe piecewise Overlay blend
    /// that `DCRWhiteBalanceBody` uses to combine the tinted RGB
    /// with the warm target.
    static let whiteBalancePrivate: String = """
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
    """

    /// MIRROR: `Shaders/ColorGrading/Vibrance/VibranceFilter.metal`
    /// Vibrance-specific constants (boost curve edges, skin-hue gate
    /// parameters) and the two small helpers `DCRVibranceAbs
    /// AngularDiff` / `DCRVibranceSkinHueGate` that
    /// `DCRVibranceBody` references.
    static let vibrancePrivate: String = """
    constant float kDCRVibranceCLow  = 0.08f;
    constant float kDCRVibranceCHigh = 0.25f;
    constant float kDCRVibranceSkinHueCenter     = 0.785398163f;
    constant float kDCRVibranceSkinHueInnerEdge  = 0.305432619f;
    constant float kDCRVibranceSkinHueOuterEdge  = 0.566502879f;

    static inline float DCRVibranceAbsAngularDiff(float h1, float h2) {
        float d = h1 - h2;
        if (d >  M_PI_F) d -= 2.0f * M_PI_F;
        if (d < -M_PI_F) d += 2.0f * M_PI_F;
        return abs(d);
    }

    static inline float DCRVibranceSkinHueGate(float h) {
        const float delta = DCRVibranceAbsAngularDiff(h, kDCRVibranceSkinHueCenter);
        return 1.0f - smoothstep(kDCRVibranceSkinHueInnerEdge, kDCRVibranceSkinHueOuterEdge, delta);
    }
    """

    /// MIRROR: `Shaders/LUT/LUT3D/LUT3DFilter.metal`
    /// Software trilinear 3D-LUT sampler + triangular dither for
    /// banding-free 8-bit output. Used by `DCRLUT3DBody`.
    static let lut3DPrivate: String = """
    inline float4 dcr_sampleLUT3D(texture3d<float, access::read> lut, float3 rgb) {
        const float size = float(lut.get_width());
        const float maxIdx = size - 1.0f;
        const float3 coord = rgb * maxIdx;

        const float3 lo = floor(coord);
        const float3 hi = min(lo + 1.0f, maxIdx);
        const float3 frac = coord - lo;

        const uint3 c0 = uint3(lo);
        const uint3 c1 = uint3(hi);

        const float4 v000 = lut.read(uint3(c0.x, c0.y, c0.z));
        const float4 v100 = lut.read(uint3(c1.x, c0.y, c0.z));
        const float4 v010 = lut.read(uint3(c0.x, c1.y, c0.z));
        const float4 v110 = lut.read(uint3(c1.x, c1.y, c0.z));
        const float4 v001 = lut.read(uint3(c0.x, c0.y, c1.z));
        const float4 v101 = lut.read(uint3(c1.x, c0.y, c1.z));
        const float4 v011 = lut.read(uint3(c0.x, c1.y, c1.z));
        const float4 v111 = lut.read(uint3(c1.x, c1.y, c1.z));

        const float4 m00 = mix(v000, v100, frac.x);
        const float4 m10 = mix(v010, v110, frac.x);
        const float4 m01 = mix(v001, v101, frac.x);
        const float4 m11 = mix(v011, v111, frac.x);

        const float4 m0 = mix(m00, m10, frac.y);
        const float4 m1 = mix(m01, m11, frac.y);

        return mix(m0, m1, frac.z);
    }

    inline half3 dcr_triangularDither(uint2 pos, half3 color) {
        float2 seed = float2(pos) * float2(12.9898f, 78.233f);
        float noise1 = fract(sin(dot(seed, float2(1.0f, 1.0f))) * 43758.5453f);
        float noise2 = fract(sin(dot(seed, float2(0.3183f, 0.7071f))) * 22578.1459f);
        float tri = noise1 - noise2;
        return color + half3(half(tri) * half(1.0f / 255.0f));
    }
    """

    /// MIRROR: `Shaders/Blend/Normal/NormalBlendFilter.metal`
    /// Manual bilinear read of the overlay texture. Used by
    /// `DCRNormalBlendBody`.
    static let normalBlendPrivate: String = """
    inline half4 dcr_blendBilinear(texture2d<half, access::read> tex, float2 coord) {
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
    """

    /// Source-tap abstraction for neighborRead bodies.
    ///
    /// `DCRRawSourceTap` is the un-fused variant: it wraps the
    /// primary `input` texture and provides a bounds-clamped
    /// `read(int2)` accessor. NeighborRead bodies (Sharpen,
    /// FilmGrain, CCD) are templated on the tap type and always call
    /// `tap.read(int2)`; codegen can substitute a different tap
    /// struct (one that pre-applies an upstream pixelLocal body
    /// before returning each sample) when `KernelInlining` has
    /// scheduled head fusion. Substituting at the tap layer keeps
    /// the body source unchanged across fused / un-fused dispatches.
    static let sourceTap: String = """
    struct DCRRawSourceTap {
        texture2d<half, access::read> src;
        inline half4 read(int2 pos) const {
            const uint2 c = uint2(
                clamp(pos.x, 0, int(src.get_width()) - 1),
                clamp(pos.y, 0, int(src.get_height()) - 1)
            );
            return src.read(c);
        }
    };
    """

    /// MIRROR: `Shaders/Effects/FilmGrain/FilmGrainFilter.metal`
    /// Symmetric SoftLight (`dcr_softLight`) used by the grain
    /// body to mix synthetic noise into the source pixel.
    static let filmGrainPrivate: String = """
    inline half dcr_softLight(half base, half blend) {
        return base + (2.0h * blend - 1.0h) * base * (1.0h - base);
    }
    """

    /// MIRROR: `Shaders/Effects/CCD/CCDFilter.metal`
    /// Rec.709 luma constant + CCD-private SoftLight helper. The
    /// previous `dcr_ccdSafeRead` helper is retired in favour of
    /// `DCRRawSourceTap` / `KernelInlining` fused-tap codegen
    /// (see `sourceTap`).
    static let ccdPrivate: String = """
    inline half dcr_ccdSoftLight(half base, half blend) {
        return base + (2.0h * blend - 1.0h) * base * (1.0h - base);
    }
    """

    // MARK: - Per-filter helper dependency map

    /// Return the helper text blocks that must precede the body
    /// function for the given filter to compile. Order matters —
    /// helper blocks are injected in this order, so a helper that
    /// depends on another must come after it.
    ///
    /// Step 3a supports the seven pure `.pixelLocalOnly` filters.
    /// Other signature shapes (LUT3D / NormalBlend / neighbour-
    /// read) will extend this switch in later steps.
    static func helpersForBody(named bodyFunctionName: String) -> [String] {
        switch bodyFunctionName {
        case "DCRExposureBody",
             "DCRContrastBody",
             "DCRBlacksBody",
             "DCRWhitesBody":
            return [srgbGamma]
        case "DCRWhiteBalanceBody":
            return [srgbGamma, whiteBalancePrivate]
        case "DCRSaturationBody":
            // OKLab helpers only — Saturation is hard-contracted to
            // linear sRGB input via Swift-side `precondition`, so no
            // sRGB gamma round-trip is needed in the kernel.
            return [oklab]
        case "DCRVibranceBody":
            // Same hard-contract as Saturation; Vibrance adds the
            // skin-hue gate via `vibrancePrivate`.
            return [oklab, vibrancePrivate]
        case "DCRLUT3DBody":
            return [srgbGamma, lut3DPrivate]
        case "DCRNormalBlendBody":
            return [normalBlendPrivate]
        case "DCRSharpenBody":
            return [sourceTap]
        case "DCRFilmGrainBody":
            return [filmGrainPrivate, sourceTap]
        case "DCRCCDBody":
            return [ccdPrivate, sourceTap]
        default:
            // Unknown body name — caller handles this by detecting
            // an empty result; MetalSourceBuilder surfaces it as
            // an `.unsupportedBodyHelpers` error.
            return []
        }
    }

    /// Returns the set of filter body function names that
    /// `FusionHelperSource` knows how to supply helpers for. Used by
    /// `MetalSourceBuilder.build(...)` to validate that a Node can
    /// actually be code-generated before attempting to produce
    /// source text.
    static let supportedBodyFunctionNames: Set<String> = [
        "DCRExposureBody",
        "DCRContrastBody",
        "DCRBlacksBody",
        "DCRWhitesBody",
        "DCRWhiteBalanceBody",
        "DCRSaturationBody",
        "DCRVibranceBody",
        "DCRLUT3DBody",
        "DCRNormalBlendBody",
        "DCRSharpenBody",
        "DCRFilmGrainBody",
        "DCRCCDBody",
    ]
}
