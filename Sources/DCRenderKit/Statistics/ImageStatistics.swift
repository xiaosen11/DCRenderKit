//
//  ImageStatistics.swift
//  DCRenderKit
//
//  Utilities for computing scalar image statistics (mean luma, etc.) that
//  feed into adaptive filter parameters like ContrastFilter.lumaMean.
//

import Foundation
import Metal

/// Scalar image statistics producer.
///
/// Filters like `ContrastFilter` and `WhitesFilter` adapt their curve
/// to the source's mean luminance. This type provides the probe that
/// drives those parameters.
///
/// ## Implementation
///
/// Built on top of `MPSDispatcher.encodeMeanReduction`, which uses
/// hardware simdgroup reductions to compute a 1×1 RGBA mean. This call
/// encodes the reduction, commits, waits for GPU completion, reads the
/// 1×1 back to CPU, and projects to luma with Rec.709 weights.
///
/// ## Cost
///
/// ~0.2–1 ms on Apple Silicon for ≤ 12MP images (the expensive part is
/// the synchronous GPU → CPU readback, not the reduction itself). Call
/// **once per source image**, cache the result, and feed it into any
/// number of filter runs. Do NOT call per frame in a realtime pipeline.
///
/// ## Thread safety
///
/// The static method is thread-safe (no shared mutable state). Each
/// call creates and commits its own command buffer.
public enum ImageStatistics {

    /// Compute the mean Rec.709 luminance of the given texture.
    ///
    /// - Parameters:
    ///   - texture: Source texture. Any `float` or `unorm` pixel format
    ///     is supported; `rgba16Float` and `bgra8Unorm` are the common
    ///     cases. Alpha is ignored.
    ///   - device: Metal device (default shared).
    /// - Returns: A scalar luma mean in the same numeric domain as the
    ///   source RGB channels (typically `[0, 1]` for Unorm / clamped
    ///   Float sources).
    /// - Throws: `PipelineError.device(.commandBufferCreationFailed)`
    ///   if the command queue can't produce a buffer, or whatever
    ///   `MPSDispatcher.encodeMeanReduction` raises on failure (e.g.
    ///   MetalPerformanceShaders unavailable on the platform).
    public static func lumaMean(
        of texture: MTLTexture,
        device: Device = .shared
    ) async throws -> Float {
        guard let commandBuffer = device.makeCommandBufferIfAvailable() else {
            throw PipelineError.device(.commandBufferCreationFailed)
        }

        let meanTexture = try MPSDispatcher.encodeMeanReduction(
            source: texture,
            device: device,
            commandBuffer: commandBuffer
        )

        // Box the 1×1 mean texture so we can capture it in the
        // completion-handler closure without tripping Swift 6's
        // non-Sendable-capture warning. The texture is written by the
        // GPU and read after the completion handler fires, so there's
        // no concurrent access to worry about.
        let meanBox = LumaTextureBox(meanTexture)

        return try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if let error = buffer.error {
                    continuation.resume(throwing: PipelineError.device(
                        .gpuExecutionFailed(underlying: error)
                    ))
                    return
                }
                let luma = readLumaFromMean(texture: meanBox.texture)
                continuation.resume(returning: luma)
            }
            commandBuffer.commit()
        }
    }

    // MARK: - Sendable box
    //
    // Holds an `MTLTexture` reference so it can be captured by a
    // `@Sendable` closure. Justified as @unchecked because the texture
    // is only read after `addCompletedHandler` fires, i.e. after the
    // GPU writes have committed; there is no concurrent access hazard.
    private struct LumaTextureBox: @unchecked Sendable {
        let texture: MTLTexture
        init(_ texture: MTLTexture) { self.texture = texture }
    }

    // MARK: - Private

    /// Read a 1×1 RGBA texture and project it to Rec.709 luma.
    ///
    /// Handles the two common pixel formats that flow through DCRenderKit:
    /// `.rgba16Float` (typical intermediate + MPS output for float sources)
    /// and `.bgra8Unorm` (8-bit display-ready buffers). Unsupported formats
    /// return 0.5 as a safe midpoint so downstream adaptive filters don't
    /// crash on an exotic input — but consumers should use one of the two
    /// supported formats for correct results.
    private static func readLumaFromMean(texture: MTLTexture) -> Float {
        switch texture.pixelFormat {
        case .rgba16Float:
            var raw = [UInt16](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { bytes in
                texture.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: 8,
                    from: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0
                )
            }
            let r = Float(Float16(bitPattern: raw[0]))
            let g = Float(Float16(bitPattern: raw[1]))
            let b = Float(Float16(bitPattern: raw[2]))
            return 0.2126 * r + 0.7152 * g + 0.0722 * b

        case .bgra8Unorm, .bgra8Unorm_srgb:
            var raw = [UInt8](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { bytes in
                texture.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: 4,
                    from: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0
                )
            }
            // BGRA byte order.
            let b = Float(raw[0]) / 255.0
            let g = Float(raw[1]) / 255.0
            let r = Float(raw[2]) / 255.0
            return 0.2126 * r + 0.7152 * g + 0.0722 * b

        case .rgba8Unorm, .rgba8Unorm_srgb:
            var raw = [UInt8](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { bytes in
                texture.getBytes(
                    bytes.baseAddress!,
                    bytesPerRow: 4,
                    from: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0
                )
            }
            let r = Float(raw[0]) / 255.0
            let g = Float(raw[1]) / 255.0
            let b = Float(raw[2]) / 255.0
            return 0.2126 * r + 0.7152 * g + 0.0722 * b

        default:
            DCRLogging.logger.warning(
                "lumaMean readback fell back on midpoint 0.5 — unsupported format",
                category: "ImageStatistics",
                attributes: ["format": "\(texture.pixelFormat.rawValue)"]
            )
            return 0.5
        }
    }
}

// MARK: - Device helper

private extension Device {

    /// Make a one-shot command buffer; returns nil if the shared queue
    /// can't produce one. Kept fileprivate so the public API surface
    /// stays focused.
    func makeCommandBufferIfAvailable() -> MTLCommandBuffer? {
        metalDevice.makeCommandQueue()?.makeCommandBuffer()
    }
}
