//
//  DCRColorSpace.swift
//  DCRenderKit
//
//  Color-space convention selector. Decides whether textures are loaded
//  and processed as perceptually-encoded gamma values or linearized
//  scene-light values.
//

import Foundation
import Metal

/// The numerical domain used by intermediate textures and filter math.
///
/// DCRenderKit can operate in two modes. They differ in what numbers the
/// floats inside `rgba16Float` intermediates represent.
///
/// - ``perceptual``: values are sRGB-gamma encoded. Matches Harbeth's
///   historical behaviour and DigiCam's visual parity target: filters'
///   curves inherit fitted constants from the Harbeth lineage, originally
///   tuned against gamma-space JPEG exports from a consumer photo-editing
///   app (fitting pipeline lost; no pixel-level parity claim against any
///   specific app — see findings-and-plan.md §8.6). Drawable presentation
///   uses `.bgra8Unorm` — byte
///   values flow unchanged from the intermediate to the screen.
///
/// - ``linear``: values represent linear scene light. Source textures are
///   loaded with GPU-side sRGB→linear conversion (`MTKTextureLoader`
///   option `.SRGB: true`), math such as Reinhard tone-mapping is
///   mathematically correct in linear space, and the final drawable is
///   `.bgra8Unorm_srgb` so the GPU gamma-encodes on write. More "correct"
///   by the lights of modern imaging, but the parameter tuning done
///   against perceptual-space references (Exposure's Reinhard gain,
///   Contrast's cubic pivot, Whites/Blacks weighted parabolas, the white-
///   balance YIQ mix) shifts the effective curve shape — product "feel"
///   will drift vs. the DigiCam baseline unless the curves are refit.
///
/// ## Switching
///
/// Change `DCRenderKit.defaultColorSpace` to choose. The enum powers:
///   1. ``TextureLoader.makeTexture`` — loads with sRGB read-side conversion
///   2. ``ExposureFilter`` — picks its shader branch (pow(,2.2) in
///      perceptual mode, identity in linear mode)
///   3. ``recommendedDrawablePixelFormat`` — the right MTKView format
///      for on-screen presentation
///
/// Other filters (Contrast, Whites, Blacks, Saturation, Vibrance,
/// WhiteBalance, Sharpen, FilmGrain, CCD, HighlightShadow, Clarity,
/// SoftGlow, PortraitBlur, NormalBlend, LUT3D, SaturationRec709) have no
/// space-sensitive code; their shader math runs on whatever numeric
/// distribution the intermediate carries. "Same math, different feel" —
/// the product-side tuning is the variable, not the math.
public enum DCRColorSpace: Sendable, Equatable {

    /// Gamma-encoded values. DigiCam parity.
    case perceptual

    /// Linear scene-light values. Mathematically correct for radiometric
    /// operations.
    case linear

    /// Pixel format a client-side drawable (typically a `CAMetalDrawable`
    /// or an MTKView's `colorPixelFormat`) should use to display the
    /// pipeline's output correctly in this color space.
    ///
    /// - ``perceptual`` → `.bgra8Unorm` — bytes flow through unchanged.
    /// - ``linear`` → `.bgra8Unorm_srgb` — GPU gamma-encodes on write.
    public var recommendedDrawablePixelFormat: MTLPixelFormat {
        switch self {
        case .perceptual: return .bgra8Unorm
        case .linear:     return .bgra8Unorm_srgb
        }
    }

    /// Whether `MTKTextureLoader` should apply sRGB→linear conversion on
    /// texture load. Consumers of `TextureLoader.makeTexture(from:CGImage)`
    /// read this to pick the right `.SRGB` option value.
    public var loaderShouldLinearize: Bool {
        switch self {
        case .perceptual: return false
        case .linear:     return true
        }
    }
}
