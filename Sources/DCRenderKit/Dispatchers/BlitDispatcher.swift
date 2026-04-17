//
//  BlitDispatcher.swift
//  DCRenderKit
//
//  Thin, safe wrappers over `MTLBlitCommandEncoder` operations. Blit is the
//  fastest way to move pixels around on the GPU (zero CPU involvement) and
//  is used for texture-to-texture copies, crops, fills, and mipmap generation.
//

import Foundation
import Metal

/// Encodes blit operations with validation and consistent error reporting.
///
/// Unlike the compute and render dispatchers, blit operations have no
/// shaders and no parameters — they're pure memory movement on the GPU.
/// This dispatcher exists to:
///
/// - Validate input textures before submitting (format matches, dimensions
///   fit, etc) instead of failing at the Metal driver level
/// - Provide a consistent encoding entry point (labeled encoder for
///   Instruments, standardized error types)
/// - Centralize mipmap generation and fill operations
public struct BlitDispatcher {

    // MARK: - Texture copy

    /// Copy the entire contents of `source` into `destination`.
    ///
    /// - Parameters:
    ///   - source: The texture to read from. Must have `.shaderRead` or
    ///     equivalent usage.
    ///   - destination: The texture to write to. Must have `.shaderWrite`
    ///     or equivalent usage.
    ///   - commandBuffer: Buffer to encode into.
    /// - Throws: `PipelineError.texture(.formatMismatch)` if source and
    ///   destination differ in format or dimensions.
    public static func copy(
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard source.pixelFormat == destination.pixelFormat else {
            throw PipelineError.texture(.formatMismatch(
                expected: "\(source.pixelFormat)",
                got: "\(destination.pixelFormat)"
            ))
        }
        guard source.width == destination.width,
              source.height == destination.height else {
            throw PipelineError.texture(.formatMismatch(
                expected: "\(source.width)x\(source.height)",
                got: "\(destination.width)x\(destination.height)"
            ))
        }

        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .blit))
        }
        encoder.label = "DCR.Blit.Copy"
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(
                width: source.width,
                height: source.height,
                depth: 1
            ),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
    }

    // MARK: - Region copy (crop / sub-region)

    /// Copy a rectangular region from `source` into `destination` at the
    /// given origin.
    ///
    /// Typical use: cropping a region out of a larger texture into a
    /// purpose-sized destination.
    ///
    /// - Parameters:
    ///   - source: The texture to read from.
    ///   - sourceRegion: Rectangular region (origin + size) within source.
    ///   - destination: The texture to write to.
    ///   - destinationOrigin: Top-left corner in destination where the
    ///     copied region lands.
    ///   - commandBuffer: Buffer to encode into.
    /// - Throws: `formatMismatch` on format mismatch; `dimensionsInvalid`
    ///   if the region doesn't fit within source or destination.
    public static func copyRegion(
        source: MTLTexture,
        sourceRegion: MTLRegion,
        destination: MTLTexture,
        destinationOrigin: MTLOrigin,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard source.pixelFormat == destination.pixelFormat else {
            throw PipelineError.texture(.formatMismatch(
                expected: "\(source.pixelFormat)",
                got: "\(destination.pixelFormat)"
            ))
        }

        // Validate source region fits within source texture.
        let srcEndX = sourceRegion.origin.x + sourceRegion.size.width
        let srcEndY = sourceRegion.origin.y + sourceRegion.size.height
        guard srcEndX <= source.width, srcEndY <= source.height,
              sourceRegion.origin.x >= 0, sourceRegion.origin.y >= 0 else {
            throw PipelineError.texture(.dimensionsInvalid(
                width: sourceRegion.size.width,
                height: sourceRegion.size.height,
                reason: "source region extends beyond source texture bounds"
            ))
        }

        // Validate destination region fits within destination texture.
        let dstEndX = destinationOrigin.x + sourceRegion.size.width
        let dstEndY = destinationOrigin.y + sourceRegion.size.height
        guard dstEndX <= destination.width, dstEndY <= destination.height,
              destinationOrigin.x >= 0, destinationOrigin.y >= 0 else {
            throw PipelineError.texture(.dimensionsInvalid(
                width: sourceRegion.size.width,
                height: sourceRegion.size.height,
                reason: "destination region extends beyond destination texture bounds"
            ))
        }

        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .blit))
        }
        encoder.label = "DCR.Blit.CopyRegion"
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: sourceRegion.origin,
            sourceSize: sourceRegion.size,
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: destinationOrigin
        )
        encoder.endEncoding()
    }

    // MARK: - Mipmap generation

    /// Generate mipmaps for a texture.
    ///
    /// - Parameters:
    ///   - texture: Must have `mipmapLevelCount > 1` and `.pixelFormatView`
    ///     or `.renderTarget` usage.
    ///   - commandBuffer: Buffer to encode into.
    public static func generateMipmaps(
        texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard texture.mipmapLevelCount > 1 else {
            throw PipelineError.texture(.dimensionsInvalid(
                width: texture.width,
                height: texture.height,
                reason: "texture has no mip levels (mipmapLevelCount=\(texture.mipmapLevelCount))"
            ))
        }

        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .blit))
        }
        encoder.label = "DCR.Blit.GenerateMipmaps"
        encoder.generateMipmaps(for: texture)
        encoder.endEncoding()
    }
}
