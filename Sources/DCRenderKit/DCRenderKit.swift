// DCRenderKit
//
// A commercial-grade Metal-based image processing SDK for iOS.
// (macOS 15 is retained only as a `swift test` host for the Metal
// compute kernels; no macOS business-layer APIs are shipped.)
//
// Public API surface — everything the consumer ever imports. See
// `docs/metal-engine-plan.md` for the architecture, and the per-type
// SwiftDoc for usage.
//
// ## Color Space Convention
//
// DCRenderKit operates in one of two color spaces, chosen via
// `DCRenderKit.defaultColorSpace`:
//
// - `.linear` (default): Textures load with GPU-side sRGB→linear
//   conversion, intermediate `rgba16Float` textures carry linear
//   scene-light values, and drawable presentation uses
//   `.bgra8Unorm_srgb` (GPU re-encodes to gamma on write). Reinhard
//   tone-mapping in ExposureFilter, Rec.709 luma weighting, and any
//   radiometric math are mathematically correct in this space.
//
// - `.perceptual`: Textures load as-is (sRGB-gamma encoded values),
//   intermediates carry gamma floats, drawable uses `.bgra8Unorm`.
//   This is the DigiCam parity mode. Tone operators (Contrast /
//   Whites / Blacks / Exposure) are principled primitives (DaVinci
//   log-slope / Filmic shoulder / Reinhard toe / Reinhard tonemap)
//   that apply in whichever numeric domain the intermediate carries.
//
// Switching requires a single line change to `DCRenderKit.defaultColorSpace`
// + rebuild. No refit is required; the principled operators retain
// their closed-form coefficients and the "feel" shifts with the
// space. If the `.linear` feel is unacceptable on device, flip back
// to `.perceptual`.

import Foundation

/// SDK metadata and global configuration.
///
/// Consumers don't normally touch this; `Pipeline` is the working
/// entry point. Included here to standardize version reporting plus the
/// SDK-wide color-space switch.
public enum DCRenderKit {

    /// Current SDK version following SemVer 2.0.
    public static let version = "0.1.0-dev"

    /// Build channel. "dev" during Phase 1–2, "release" once the SDK
    /// is tagged for consumer adoption.
    public static let channel = "dev"

    /// Default color space for the SDK. Read by:
    ///   - ``TextureLoader`` — picks whether to linearize on load
    ///   - ``ExposureFilter`` — picks its shader branch
    ///   - ``Pipeline.init`` — stored as ``Pipeline.colorSpace``
    ///   - Demo / consumers — `MTKView.colorPixelFormat` via
    ///     `DCRColorSpace.recommendedDrawablePixelFormat`
    ///
    /// Change this to `.perceptual` at compile time to revert to the
    /// DigiCam parity pipeline. The rebuild is the flip — no code
    /// elsewhere needs to change.
    public static let defaultColorSpace: DCRColorSpace = .linear
}
