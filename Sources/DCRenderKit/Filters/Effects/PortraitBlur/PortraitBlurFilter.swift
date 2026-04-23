//
//  PortraitBlurFilter.swift
//  DCRenderKit
//
//  Subject-aware depth-of-field blur. Two-pass Poisson-disc stochastic
//  blur: the second pass samples a 90°-rotated variant of the first
//  pass's Poisson pattern, so the 16-tap kernel in effect draws from
//  32 uncorrelated sample positions — that is what kills the residual
//  banding 16-tap Poisson-disc shows at large radii.
//
//  Ported from DigiCam originally as a single-pass filter; upgraded to
//  the two-pass architecture in Session C for the "slider +100 feels
//  weak" real-device report (#75).
//

import Foundation
import Metal

#if canImport(Vision)
import Vision
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

/// Subject-mask-driven depth-of-field blur.
///
/// ## Model form justification
///
/// - Type: 2D neighbourhood (mask-modulated variable radius)
/// - Algorithm: **Two-pass Poisson-disc** stochastic blur.
///   - 16-tap Poisson pattern per pass, Gaussian-weighted by distance
///     from centre (Mitchell, "Spectrally Optimal Sampling for
///     Distribution Ray Tracing", SIGGRAPH 1991).
///   - Pass 1 reads the source texture; pass 2 reads pass 1's output
///     and uses a **90°-rotated** copy of the same Poisson pattern.
///     The two passes together draw from **32 uncorrelated sample
///     positions** — `rotate(p, 90°)` never coincides with `p` for
///     any non-origin Poisson tap, so second-pass samples land in
///     the gaps left by the first pass.
///   - Effective standard deviation is `σ_single × √2`, matching the
///     Gaussian convolution-of-two-Gaussians identity. Per-pass radius
///     of `0.030 · shortSide` produces an effective `0.0424 · shortSide`
///     blur: ~46 px at 1080p, ~92 px at 4K — the Apple Portrait / LR
///     50-100 px range that real-device feedback (#75) called out as
///     the target.
/// - Why **not** separable Gaussian: mask-modulated per-pixel radius
///   breaks the space-invariance assumption that lets Gaussian
///   convolution be separated into two 1D passes. Variable-σ separable
///   Gaussian is an approximation whose quality at sharp mask
///   boundaries is worse than the uncorrelated-stochastic approach
///   used here.
/// - Why **not** disk DoF: disk DoF requires a depth map, but the SDK's
///   `PortraitBlurMaskGenerator` returns a binary subject mask — there
///   is no depth signal to drive a physically-correct CoC radius.
/// - Why **not** Dual Kawase pyramid: pyramid blur is fixed-radius
///   per-level; mask-modulated per-pixel radius cannot be expressed
///   in the pyramid.
///
/// ## Pass graph
///
/// 1. **pass1** (`DCRPortraitBlurFilterPass1`): `source + mask → temp`.
///    Standard Poisson-disc pattern; `localRadius = (1 − mask) · strength
///    · shortSide · 0.030`.
/// 2. **final** (`DCRPortraitBlurFilterPass2`): `temp + mask → output`.
///    Pattern rotated 90° in-shader; same radius formula.
///
/// Identity short-circuit: when the filter was built with `maskTexture
/// == nil`, `passes(input:)` returns an empty array and the SDK falls
/// through to passing `source` unchanged. When `strength == 0`, pass 1
/// still runs but its output matches the input within Float16 noise
/// (dead-zone handled inside the shader); we don't short-circuit at
/// strength=0 in Swift to keep the pass graph shape stable for
/// downstream snapshot testing.
///
/// ## Spatial parameter (rules/spatial-params.md §2)
///
/// `localRadius = (1 − mask) · strength · shortSide · 0.030` is an
/// image-structure parameter. Coefficient 0.030 chosen so the
/// **effective** (two-pass) radius of 0.0424 · shortSide places the
/// slider's +100 endpoint in the Apple Portrait / Lightroom 50-100 px
/// range on both 1080p and 4K inputs.
///
/// ## Sendable note
///
/// Stores an `MTLTexture` mask, which is not natively `Sendable`. The
/// mask is immutable after `init` and read by the shader with
/// `.shaderRead` — the standard safe-to-share pattern for read-only
/// Metal resources. `@unchecked Sendable` carries that justification.
public struct PortraitBlurFilter: MultiPassFilter, @unchecked Sendable {

    /// Blur strength slider, `0 ... 100`. Internally normalised to
    /// `0.0 ... 1.0` for the shader. No product compression: the
    /// coefficient in the shader (`0.030 · shortSide`) already
    /// encodes the desired product-level feel.
    public var strength: Float

    /// Subject mask texture (R8Unorm). `1.0` = subject (kept sharp),
    /// `0.0` = background (fully blurred). `nil` makes the filter an
    /// identity pass-through.
    private let maskTexture: MTLTexture?

    public init(strength: Float = 50, maskTexture: MTLTexture?) {
        self.strength = strength
        self.maskTexture = maskTexture
    }

    public var additionalInputs: [MTLTexture] {
        maskTexture.map { [$0] } ?? []
    }

    public func passes(input: TextureInfo) -> [Pass] {
        // Identity pass-through when no mask was provided — emit an
        // empty pass graph so the executor hands the source back
        // unchanged.
        guard maskTexture != nil else {
            return []
        }

        let uniforms = FilterUniforms(PortraitBlurUniforms(
            strength: strength / 100.0
        ))

        return [
            .compute(
                name: "pass1",
                kernel: "DCRPortraitBlurFilterPass1",
                inputs: [.source, .additional(0)],
                output: .sameAsSource,
                uniforms: uniforms
            ),
            .final(
                name: "pass2",
                kernel: "DCRPortraitBlurFilterPass2",
                inputs: [.named("pass1"), .additional(0)],
                output: .sameAsSource,
                uniforms: uniforms
            ),
        ]
    }
}

/// Memory layout matches `constant PortraitBlurUniforms& u [[buffer(0)]]`
/// in `PortraitBlurFilter.metal`.
struct PortraitBlurUniforms {
    /// Blur strength normalised to `0.0 ... 1.0`. No product
    /// compression: the shader's `0.030 · shortSide` coefficient
    /// already encodes the desired peak radius.
    var strength: Float
}

// MARK: - Vision-based mask generation

#if canImport(Vision) && canImport(CoreVideo)

/// Helpers that produce a subject mask `MTLTexture` from common image
/// sources using Vision's `VNGenerateForegroundInstanceMaskRequest`.
///
/// Vision detects any foreground subject (person, pet, food, object) —
/// equivalent to the system Camera "Portrait" mode / "Lift subject"
/// feature. Available on iOS 17+ / macOS 14+.
public enum PortraitBlurMaskGenerator {

    /// Generate a subject mask from a `CGImage`. Call once per photo
    /// (the mask is expensive to compute — cache it across filter runs
    /// if the source image is unchanged).
    ///
    /// Returns `nil` when Vision fails to detect any foreground subject
    /// or when the platform predates iOS 17 / macOS 14.
    @available(iOS 17.0, macOS 14.0, *)
    public static func generate(
        from image: CGImage,
        device: Device = .shared
    ) -> MTLTexture? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return maskTexture(from: observation, handler: handler, device: device)
    }

    /// Generate a subject mask from a `CVPixelBuffer`. Intended for
    /// camera-preview frames; typically re-run every N frames rather than
    /// every frame (Vision is not realtime-cheap).
    @available(iOS 17.0, macOS 14.0, *)
    public static func generate(
        from pixelBuffer: CVPixelBuffer,
        device: Device = .shared
    ) -> MTLTexture? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return maskTexture(from: observation, handler: handler, device: device)
    }

    // MARK: - Private

    @available(iOS 17.0, macOS 14.0, *)
    private static func maskTexture(
        from observation: VNInstanceMaskObservation,
        handler: VNImageRequestHandler,
        device: Device
    ) -> MTLTexture? {
        let instances = observation.allInstances
        guard !instances.isEmpty else { return nil }

        guard let maskBuffer = try? observation.generateScaledMaskForImage(
            forInstances: instances,
            from: handler
        ) else {
            return nil
        }
        return pixelBufferToR8Unorm(maskBuffer, device: device)
    }

    private static func pixelBufferToR8Unorm(
        _ buffer: CVPixelBuffer,
        device: Device
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.metalDevice.makeTexture(descriptor: descriptor) else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        switch pixelFormat {
        case kCVPixelFormatType_OneComponent8:
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        case kCVPixelFormatType_OneComponent32Float:
            let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)
            let strideInFloats = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
            var u8 = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let v = floatPtr[y * strideInFloats + x]
                    u8[y * width + x] = UInt8(min(max(v, 0) * 255, 255))
                }
            }
            u8.withUnsafeBufferPointer { ptr in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: width
                )
            }
        default:
            return nil
        }
        return texture
    }
}

#endif  // canImport(Vision) && canImport(CoreVideo)
