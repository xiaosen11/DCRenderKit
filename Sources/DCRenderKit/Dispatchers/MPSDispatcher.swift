//
//  MPSDispatcher.swift
//  DCRenderKit
//
//  Thin wrappers over frequently-used Metal Performance Shaders kernels.
//  Treated as an *optional* acceleration layer: DCRenderKit never requires
//  MPS, and cross-platform code paths are expected to provide a
//  compute-shader fallback when MPS is unavailable.
//

import Foundation
import Metal

#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

/// Optional Apple Metal Performance Shaders acceleration.
///
/// ## Design stance
///
/// DCRenderKit's core algorithms are implemented as cross-platform compute
/// shaders to maximize portability (iOS, macOS, and future Vulkan/WebGPU
/// targets). `MPSDispatcher` is provided as an *optional* acceleration
/// layer for Apple-exclusive deployments that can afford to trade
/// portability for 10-20% performance on specific kernels.
///
/// ## Availability
///
/// MPS is available on iOS 9+ and macOS 10.13+ (all platforms DCRenderKit
/// supports), so `isAvailable` is effectively always `true` at runtime.
/// The availability check exists so future tvOS or cross-platform targets
/// can conditionally enable MPS.
///
/// ## When to use MPS
///
/// - Gaussian blur with large sigma (>20 px) — MPS uses highly-tuned
///   separable convolution that beats naive compute implementations.
/// - Image statistics (mean, variance, min/max) — MPS uses simdgroup
///   reductions that we'd otherwise have to write ourselves.
/// - High-quality resampling (Lanczos) — tedious to implement in compute.
/// - Gaussian pyramid — a few passes but MPS bundles them.
///
/// ## When NOT to use MPS
///
/// - Algorithms where we have a working compute implementation (stickiness
///   with the cross-platform path is worth 15% perf).
/// - Small operations where the MPS kernel setup cost dominates the
///   actual work (e.g. small-radius blurs).
/// - Any code path that might need to run on non-Apple platforms.
public struct MPSDispatcher {

    // MARK: - Availability

    /// Whether Apple Metal Performance Shaders is available on the current
    /// platform. Always true on iOS and macOS.
    public static var isAvailable: Bool {
        #if canImport(MetalPerformanceShaders)
        return true
        #else
        return false
        #endif
    }

    // MARK: - Gaussian blur

    /// Apply a Gaussian blur to `source`, writing the result to `destination`.
    ///
    /// - Parameters:
    ///   - source: Input texture.
    ///   - destination: Output texture (same dimensions and format as source).
    ///   - sigma: Gaussian standard deviation in pixels. Larger = more blur.
    ///     Common range 1-50.
    ///   - device: Metal device wrapping the target GPU.
    ///   - commandBuffer: Buffer to encode into.
    /// - Throws: `PipelineError.pipelineState(.libraryLoadFailed)` if MPS
    ///   is unavailable on the current platform.
    public static func gaussianBlur(
        source: MTLTexture,
        destination: MTLTexture,
        sigma: Float,
        device: Device = .shared,
        commandBuffer: MTLCommandBuffer
    ) throws {
        #if canImport(MetalPerformanceShaders)
        guard sigma > 0 else {
            // No-op: copy source to destination via blit.
            try BlitDispatcher.copy(
                source: source,
                destination: destination,
                commandBuffer: commandBuffer
            )
            return
        }
        let blur = MPSImageGaussianBlur(device: device.metalDevice, sigma: sigma)
        blur.edgeMode = .clamp
        blur.encode(
            commandBuffer: commandBuffer,
            sourceTexture: source,
            destinationTexture: destination
        )
        #else
        throw PipelineError.pipelineState(.libraryLoadFailed(
            reason: "MetalPerformanceShaders not available on this platform"
        ))
        #endif
    }

    // MARK: - Image statistics

    /// Compute the mean RGBA value across an input texture. Useful as a
    /// hardware-accelerated `lumaMean` probe for adaptive filters.
    ///
    /// - Parameters:
    ///   - source: Input texture.
    ///   - device: Metal device.
    ///   - commandBuffer: Buffer to encode into.
    /// - Returns: A single-pixel (1x1) destination texture containing the
    ///   mean value. Caller must wait for `commandBuffer` completion before
    ///   reading back.
    public static func encodeMeanReduction(
        source: MTLTexture,
        device: Device = .shared,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        #if canImport(MetalPerformanceShaders)
        let mean = MPSImageStatisticsMean(device: device.metalDevice)

        // Output is a 1×1 texture matching the input format.
        let destDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: 1, height: 1, mipmapped: false
        )
        destDesc.usage = [.shaderRead, .shaderWrite]
        destDesc.storageMode = .shared
        guard let destination = device.metalDevice.makeTexture(descriptor: destDesc) else {
            throw PipelineError.texture(.textureCreationFailed(
                reason: "Failed to allocate 1x1 destination texture for MPSImageStatisticsMean"
            ))
        }

        mean.encode(
            commandBuffer: commandBuffer,
            sourceTexture: source,
            destinationTexture: destination
        )
        return destination
        #else
        throw PipelineError.pipelineState(.libraryLoadFailed(
            reason: "MetalPerformanceShaders not available on this platform"
        ))
        #endif
    }

    // MARK: - Lanczos resampling

    /// Resize `source` into `destination` using MPS's high-quality Lanczos
    /// kernel. Preferred over bilinear or bicubic when downsampling by large
    /// factors (e.g. 12MP → 1080p thumbnail) because it preserves detail
    /// without ringing.
    public static func lanczosResample(
        source: MTLTexture,
        destination: MTLTexture,
        device: Device = .shared,
        commandBuffer: MTLCommandBuffer
    ) throws {
        #if canImport(MetalPerformanceShaders)
        let scale = MPSImageLanczosScale(device: device.metalDevice)
        scale.encode(
            commandBuffer: commandBuffer,
            sourceTexture: source,
            destinationTexture: destination
        )
        #else
        throw PipelineError.pipelineState(.libraryLoadFailed(
            reason: "MetalPerformanceShaders not available on this platform"
        ))
        #endif
    }
}

// MPSImageGaussianPyramid intentionally omitted from Round 7 — its
// `inPlaceTexture: inout MTLTexture?` API is awkward to bridge and we
// don't actually exercise it until Round 10 SoftGlow migration. Will be
// added in Round 10 alongside the filter that consumes it, where we can
// test it end-to-end.
