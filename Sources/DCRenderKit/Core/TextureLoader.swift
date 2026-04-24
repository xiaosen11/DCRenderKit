//
//  TextureLoader.swift
//  DCRenderKit
//
//  Converts the supported input types into `MTLTexture`:
//    - MTLTexture    (passthrough)
//    - CGImage       (via MTKTextureLoader — hardware-accelerated decode)
//    - UIImage       (extracts CGImage then same path)
//    - CVPixelBuffer (via CVMetalTextureCache — zero-copy for BGRA)
//

import Foundation
import Metal
import MetalKit
import CoreVideo

#if canImport(UIKit)
import UIKit
@available(iOS 18.0, *)
public typealias DCRImage = UIImage
#endif

/// Entry point for creating `MTLTexture` from any supported source type.
///
/// ## Supported inputs
///
/// | Source | Path | Notes |
/// |--------|------|-------|
/// | `MTLTexture` | passthrough | zero cost |
/// | `CGImage` | `MTKTextureLoader` | hardware-accelerated decode |
/// | `DCRImage` (UIImage) | extract CGImage → MTKTextureLoader | iOS-only |
/// | `CVPixelBuffer` (BGRA32) | `CVMetalTextureCache` | zero-copy |
///
/// Platform note: DCRenderKit is an iOS-only SDK. macOS is retained as
/// a `swift test` host for Metal compute kernels — the UIImage path is
/// compiled only under `canImport(UIKit)`. The core Metal paths
/// (CGImage / CVPixelBuffer / passthrough) work on any platform with
/// Metal support, but no NSImage shim is shipped.
///
/// YUV multi-plane `CVPixelBuffer` support is deferred until video capture
/// workflows require it.
@available(iOS 18.0, *)
public final class TextureLoader: @unchecked Sendable {

    // MARK: - Shared instance

    /// Default loader bound to `Device.shared`.
    public static let shared = TextureLoader(device: Device.shared)

    // MARK: - State

    private let device: Device
    private let mtkLoader: MTKTextureLoader
    private let lock = NSLock()
    private var pixelBufferCache: CVMetalTextureCache?

    // MARK: - Init

    public init(device: Device) {
        self.device = device
        self.mtkLoader = MTKTextureLoader(device: device.metalDevice)
    }

    // MARK: - MTLTexture passthrough

    /// No-op: returns the texture unchanged.
    public func makeTexture(from texture: MTLTexture) -> MTLTexture {
        return texture
    }

    // MARK: - CGImage

    /// Create a `MTLTexture` from a `CGImage` using hardware-accelerated
    /// decoding via `MTKTextureLoader`.
    ///
    /// - Parameters:
    ///   - cgImage: The source image.
    ///   - usage: Texture usage mask. Defaults to shaderRead-only for pure
    ///     source textures. Add `.shaderWrite` or `.renderTarget` if the
    ///     caller plans to write into this texture.
    ///   - storageMode: Defaults to `.private` for GPU efficiency. Use
    ///     `.shared` if the CPU needs to read back.
    /// - Returns: A freshly-allocated `MTLTexture` containing the decoded
    ///   image in `bgra8Unorm` format.
    /// - Throws: `PipelineError.texture(.loadFailed)` on decode failure.
    public func makeTexture(
        from cgImage: CGImage,
        usage: MTLTextureUsage = [.shaderRead],
        storageMode: MTLStorageMode = .private,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) throws -> MTLTexture {
        // `.SRGB: true` asks MTKTextureLoader to mark the resulting texture
        // as sRGB-encoded on disk, so shader reads auto-linearize via the
        // hardware sampler. `.SRGB: false` keeps raw values — the right
        // default for the DigiCam-parity perceptual mode.
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: usage.rawValue),
            .textureStorageMode: NSNumber(value: storageMode.rawValue),
            .SRGB: colorSpace.loaderShouldLinearize,
            .generateMipmaps: false,
        ]
        do {
            return try mtkLoader.newTexture(cgImage: cgImage, options: options)
        } catch {
            throw PipelineError.texture(.loadFailed(
                source: "CGImage",
                underlying: error
            ))
        }
    }

    // MARK: - DCRImage (UIImage)

    #if canImport(UIKit)
    /// Create a `MTLTexture` from a `UIImage`.
    public func makeTexture(
        from image: UIImage,
        usage: MTLTextureUsage = [.shaderRead],
        storageMode: MTLStorageMode = .private,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) throws -> MTLTexture {
        guard let cgImage = image.cgImage else {
            throw PipelineError.texture(.imageDecodeFailed(format: "UIImage (no backing CGImage)"))
        }
        return try makeTexture(
            from: cgImage, usage: usage, storageMode: storageMode, colorSpace: colorSpace
        )
    }
    #endif

    // MARK: - CVPixelBuffer

    /// Create a `MTLTexture` from a `CVPixelBuffer` using zero-copy via
    /// `CVMetalTextureCache`.
    ///
    /// Only single-plane BGRA pixel buffers are supported in Round 8. YUV
    /// multi-plane (used by camera capture in some formats) will be added
    /// when video-capture workflows need it.
    ///
    /// ## Color space handling
    ///
    /// `colorSpace` drives the resulting texture's pixel format exactly
    /// like the CGImage path. Camera CVPixelBuffers from AVFoundation
    /// always contain sRGB-gamma-encoded bytes (32BGRA standard encoding),
    /// so in `.linear` mode we return a `.bgra8Unorm_srgb`-formatted
    /// view of the same memory — the GPU sampler then linearizes on read.
    /// In `.perceptual` mode we return a `.bgra8Unorm` view so the bytes
    /// flow through unchanged (DigiCam parity).
    ///
    /// Before this parameter existed, the camera path silently used
    /// `.bgra8Unorm` regardless of SDK color space, which in `.linear`
    /// mode had filters doing linear-space math on gamma-encoded inputs
    /// — the same filter would produce different results on a CGImage
    /// vs. a CVPixelBuffer of the same scene.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The source buffer. Must have
    ///     `kCVPixelFormatType_32BGRA`.
    ///   - colorSpace: SDK color-space mode; selects whether the
    ///     resulting texture is marked sRGB-encoded (so shader reads
    ///     auto-linearize) or stays raw.
    /// - Returns: A zero-copy `MTLTexture` backed by the same memory as
    ///   `pixelBuffer`. The texture is valid as long as the pixel buffer
    ///   is retained.
    /// - Throws: `PipelineError.texture(.pixelBufferConversionFailed)` on
    ///   Core Video failure; `.pixelFormatUnsupported` for non-BGRA input.
    public func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) throws -> MTLTexture {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else {
            let formatString = fourCharCodeString(format)
            throw PipelineError.texture(.pixelFormatUnsupported(
                format: "CVPixelBuffer format \(formatString) (only 32BGRA supported in Round 8)"
            ))
        }

        let cache = try ensureCache()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let pixelFormat: MTLPixelFormat =
            colorSpace.loaderShouldLinearize ? .bgra8Unorm_srgb : .bgra8Unorm

        var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            0,  // planeIndex
            &cvMetalTexture
        )
        guard status == kCVReturnSuccess, let cvTexture = cvMetalTexture else {
            throw PipelineError.texture(.pixelBufferConversionFailed(cvReturn: status))
        }
        guard let texture = CVMetalTextureGetTexture(cvTexture) else {
            throw PipelineError.texture(.pixelBufferConversionFailed(cvReturn: -1))
        }
        return texture
    }

    // MARK: - Cache management

    private func ensureCache() throws -> CVMetalTextureCache {
        lock.lock()
        defer { lock.unlock() }

        if let cache = pixelBufferCache {
            return cache
        }

        var newCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device.metalDevice,
            nil,
            &newCache
        )
        guard status == kCVReturnSuccess, let cache = newCache else {
            throw PipelineError.texture(.pixelBufferConversionFailed(cvReturn: status))
        }
        pixelBufferCache = cache
        return cache
    }

    /// Flush the `CVMetalTextureCache`. Call periodically in long-running
    /// camera sessions to release cached textures whose source buffers have
    /// been freed.
    public func flushCache() {
        lock.lock()
        defer { lock.unlock() }
        if let cache = pixelBufferCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}

// MARK: - Helpers

private func fourCharCodeString(_ code: OSType) -> String {
    let chars: [Character] = [
        Character(UnicodeScalar((code >> 24) & 0xff) ?? " "),
        Character(UnicodeScalar((code >> 16) & 0xff) ?? " "),
        Character(UnicodeScalar((code >>  8) & 0xff) ?? " "),
        Character(UnicodeScalar( code        & 0xff) ?? " "),
    ]
    return String(chars)
}
