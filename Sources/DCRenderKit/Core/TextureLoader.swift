//
//  TextureLoader.swift
//  DCRenderKit
//
//  Converts the four supported input types into `MTLTexture`:
//    - MTLTexture       (passthrough)
//    - CGImage          (via MTKTextureLoader — hardware-accelerated decode)
//    - UIImage/NSImage  (extracts CGImage then same path)
//    - CVPixelBuffer    (via CVMetalTextureCache — zero-copy for BGRA)
//

import Foundation
import Metal
import MetalKit
import CoreVideo

#if canImport(UIKit)
import UIKit
public typealias DCRImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias DCRImage = NSImage
#endif

/// Entry point for creating `MTLTexture` from any supported source type.
///
/// ## Supported inputs
///
/// | Source | Path | Notes |
/// |--------|------|-------|
/// | `MTLTexture` | passthrough | zero cost |
/// | `CGImage` | `MTKTextureLoader` | hardware-accelerated decode |
/// | `DCRImage` (UIImage on iOS, NSImage on macOS) | extract CGImage → MTKTextureLoader | |
/// | `CVPixelBuffer` (BGRA32) | `CVMetalTextureCache` | zero-copy |
///
/// YUV multi-plane `CVPixelBuffer` support is deferred until video capture
/// workflows require it (Round 10+).
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
        storageMode: MTLStorageMode = .private
    ) throws -> MTLTexture {
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: NSNumber(value: usage.rawValue),
            .textureStorageMode: NSNumber(value: storageMode.rawValue),
            .SRGB: false,  // DCRenderKit works in linear space; keep pixels linear.
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

    // MARK: - DCRImage (UIImage / NSImage)

    #if canImport(UIKit)
    /// Create a `MTLTexture` from a `UIImage`.
    public func makeTexture(
        from image: UIImage,
        usage: MTLTextureUsage = [.shaderRead],
        storageMode: MTLStorageMode = .private
    ) throws -> MTLTexture {
        guard let cgImage = image.cgImage else {
            throw PipelineError.texture(.imageDecodeFailed(format: "UIImage (no backing CGImage)"))
        }
        return try makeTexture(from: cgImage, usage: usage, storageMode: storageMode)
    }
    #elseif canImport(AppKit)
    /// Create a `MTLTexture` from an `NSImage`.
    public func makeTexture(
        from image: NSImage,
        usage: MTLTextureUsage = [.shaderRead],
        storageMode: MTLStorageMode = .private
    ) throws -> MTLTexture {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw PipelineError.texture(.imageDecodeFailed(format: "NSImage (no backing CGImage)"))
        }
        return try makeTexture(from: cgImage, usage: usage, storageMode: storageMode)
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
    /// - Parameters:
    ///   - pixelBuffer: The source buffer. Must have
    ///     `kCVPixelFormatType_32BGRA`.
    ///   - pixelFormat: Metal pixel format to map into; defaults to
    ///     `.bgra8Unorm`. Consumers needing linear-space work should
    ///     bundle a separate sRGB→linear conversion step.
    /// - Returns: A zero-copy `MTLTexture` backed by the same memory as
    ///   `pixelBuffer`. The texture is valid as long as the pixel buffer
    ///   is retained.
    /// - Throws: `PipelineError.texture(.pixelBufferConversionFailed)` on
    ///   Core Video failure; `.pixelFormatUnsupported` for non-BGRA input.
    public func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat = .bgra8Unorm
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
