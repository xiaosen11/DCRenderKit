//
//  PortraitBlurFilter.swift
//  DCRenderKit
//
//  Subject-aware depth-of-field blur. mask=1 regions stay sharp, mask=0
//  regions are blurred with a 16-tap Poisson-disc kernel. Ported from
//  DigiCam. Static factory methods for Vision-based mask generation are
//  included for consumer convenience.
//

import Foundation
import Metal

#if canImport(Vision)
import Vision
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

/// Subject-mask driven depth-of-field blur.
///
/// ## Algorithm
///
/// - Type: 2D neighborhood with per-pixel radius modulation
/// - Kernel: 16-tap **Poisson-disc** sampling pattern inside a unit disc,
///   Gaussian-weighted by distance-from-center. Poisson-disc (vs a regular
///   grid) prevents the grid-aliased "cross" pattern common with small
///   sample counts.
///   - Reference: Mitchell, "Spectrally Optimal Sampling for Distribution
///     Ray Tracing" (SIGGRAPH '91). Modern GPU-filter adoption in
///     Unity's HDRP bokeh and UE's depth-of-field.
/// - Mask: R8Unorm texture in `[0, 1]`. 1 = subject, 0 = background.
///   `blurAmount = (1 - mask) · strength` so mask-edge pixels naturally
///   fade between sharp and blurred (no manual smoothstep needed).
///
/// ## Spatial parameter (rules/spatial-params.md §2)
///
/// `localRadius = blurAmount · shortSide · 0.025` — image-structure
/// parameter, scales with the source's short side so a given `strength`
/// produces visually comparable blur at any resolution:
/// - 1080p: max radius ≈ 27 pixels
/// - 4K:    max radius ≈ 54 pixels
///
/// ## Known limitation
///
/// 16-tap Poisson disc shows mild banding beyond ~60 pixel radii. For
/// large-aperture / very soft bokeh, apply the filter twice (the
/// banding at N samples decorrelates between applications, effectively
/// doubling the sample count). A full hybrid separable-Gaussian path
/// for large radii is a Phase 2 candidate; this port preserves exact
/// DigiCam behaviour.
///
/// ## Failure modes
///
/// The mask is required at init; pass `nil` there and the initializer
/// degrades to a no-op filter that simply returns the source. This
/// mirrors the DigiCam behaviour of "mask-less subjects = untouched
/// image" without the shader-side undefined-texture-binding hazard.
public struct PortraitBlurFilter: FilterProtocol, @unchecked Sendable {

    /// Blur strength slider `0 ... 100`.
    public var strength: Float

    /// Subject mask texture (R8Unorm). `nil` → identity behaviour.
    private let maskTexture: MTLTexture?

    public init(strength: Float = 50, maskTexture: MTLTexture?) {
        self.strength = strength
        self.maskTexture = maskTexture
    }

    public var modifier: ModifierEnum {
        // Choose between the real kernel and a trivial identity kernel
        // so that a missing mask never lets the GPU bind undefined
        // textures. The identity kernel still respects ComputeDispatcher's
        // binding convention (writes to dest, reads from source).
        if maskTexture == nil {
            return .compute(kernel: "DCRPortraitBlurIdentity")
        }
        return .compute(kernel: "DCRPortraitBlurFilter")
    }

    public var uniforms: FilterUniforms {
        FilterUniforms(PortraitBlurUniforms(
            strength: (strength / 100.0) * 0.5   // product compression ×0.5
        ))
    }

    public var additionalInputs: [MTLTexture] {
        maskTexture.map { [$0] } ?? []
    }

    public static var fuseGroup: FuseGroup? { nil }
}

/// Memory layout matches `constant PortraitBlurUniforms& u [[buffer(0)]]`.
struct PortraitBlurUniforms {
    /// Product-compressed strength `0 ... 0.5`.
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
