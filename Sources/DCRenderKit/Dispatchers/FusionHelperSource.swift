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
        const float h = atan2(lab.z, lab.y);
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
            return [oklab]
        case "DCRVibranceBody":
            return [oklab, vibrancePrivate]
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
    ]
}
