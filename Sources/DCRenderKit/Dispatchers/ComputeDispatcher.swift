//
//  ComputeDispatcher.swift
//  DCRenderKit
//
//  Encodes a single compute kernel dispatch into a command buffer. Binds the
//  standard texture/buffer slots so all DCRenderKit compute shaders share a
//  consistent interface.
//

import Foundation
import Metal

/// Encodes compute kernel dispatches with a fixed, well-documented binding
/// convention.
///
/// ## Binding convention
///
/// Every compute kernel written for DCRenderKit must follow this layout:
///
/// ```metal
/// kernel void MyFilter(
///     texture2d<half, access::write> output    [[texture(0)]],  // ← destination
///     texture2d<half, access::read>  input     [[texture(1)]],  // ← source
///     texture2d<half, access::read>  extra0    [[texture(2)]],  // ← additionalInputs[0]
///     texture2d<half, access::read>  extra1    [[texture(3)]],  // ← additionalInputs[1]
///     constant MyUniforms&           uniforms  [[buffer(0)]],   // ← FilterUniforms payload
///     uint2                          gid       [[thread_position_in_grid]])
/// {
///     if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
///     // ... kernel body
/// }
/// ```
///
/// This convention lets the dispatcher bind everything automatically. Filters
/// that need extra data (masks, LUTs, blend textures) expose them via
/// `FilterProtocol.additionalInputs` and pick up the matching texture slots
/// starting at index 2.
///
/// ## Threadgroup sizing
///
/// We pick threadgroup dimensions from `MTLComputePipelineState.threadExecutionWidth`
/// (the SIMD width of the target GPU, typically 32) × a vertical size that
/// fills one simdgroup (usually 8 on Apple Silicon, giving 32×8 = 256 threads
/// per threadgroup — a common sweet spot).
///
/// We use `dispatchThreads(_:threadsPerThreadgroup:)` (iOS 11+, macOS 10.13+)
/// which correctly handles the non-integer-multiple case: the kernel's own
/// `bounds check` (required by DCRenderKit's shader rules) handles threads
/// that fall outside the texture.
@available(iOS 18.0, *)
public struct ComputeDispatcher {

    // MARK: - Public API

    /// Encode a single compute dispatch into `commandBuffer`.
    ///
    /// - Parameters:
    ///   - kernel: Name of the compute function (matches
    ///     `ModifierEnum.compute(kernel:)`).
    ///   - uniforms: Typed parameter payload to bind at `buffer(0)`. Use
    ///     `.empty` if the kernel takes no uniforms.
    ///   - additionalInputs: Extra read textures to bind starting at
    ///     `texture(2)`. Order-preserved.
    ///   - source: Primary input texture (`texture(1)`).
    ///   - destination: Output texture (`texture(0)`). Must have `shaderWrite`
    ///     usage.
    ///   - commandBuffer: The buffer to encode into. Caller is responsible for
    ///     committing.
    ///   - psoCache: PSO cache; defaults to `PipelineStateCache.shared`.
    ///   - uniformPool: Buffer pool for uniforms; defaults to
    ///     `UniformBufferPool.shared`.
    ///   - library: ShaderLibrary that resolves `kernel`; defaults to
    ///     `ShaderLibrary.shared`. Pass an injected library when running
    ///     multiple `Pipeline`s with independent shader registrations.
    /// - Throws: `PipelineError` variants on PSO compile failure, dimension
    ///   mismatch, or encoder creation failure.
    public static func dispatch(
        kernel: String,
        uniforms: FilterUniforms = .empty,
        additionalInputs: [MTLTexture] = [],
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        psoCache: PipelineStateCache = .shared,
        uniformPool: UniformBufferPool = .shared,
        library: ShaderLibrary = .shared
    ) throws {
        // 1. Validate dimensions
        try validateDimensions(source: source, destination: destination)

        // 2. Resolve PSO (cached)
        let pso = try psoCache.computePipelineState(forKernel: kernel, library: library)

        // 3. Create compute encoder
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PipelineError.device(.commandEncoderCreationFailed(kind: .compute))
        }
        // Defensive: see ComputeBackend.execute for the same pattern.
        // If `uniformPool.nextBuffer(...)` throws between encoder
        // creation and `endEncoding()`, ARC-driven dealloc traps with
        // `Command encoder released without endEncoding`.
        var encoderEnded = false
        defer {
            if !encoderEnded {
                encoder.endEncoding()
            }
        }
        encoder.label = "DCR.Compute.\(kernel)"
        encoder.setComputePipelineState(pso)

        // 4. Bind textures (convention: 0=dest, 1=source, 2+=additional)
        encoder.setTexture(destination, index: 0)
        encoder.setTexture(source, index: 1)
        for (offset, texture) in additionalInputs.enumerated() {
            encoder.setTexture(texture, index: 2 + offset)
        }

        // 5. Bind uniforms at buffer(0) if non-empty.
        //
        // Two paths:
        //  - ≤ 4 KB (covers every filter we ship): `setBytes`, which
        //    lets Metal manage per-dispatch transient storage internally.
        //  - > 4 KB: `UniformBufferPool`, which now reserves buffers
        //    per command buffer and grows on demand. Both paths are
        //    correct under unlimited dispatches per command buffer.
        if uniforms.byteCount > 0 {
            if uniforms.byteCount <= 4096 {
                var scratch = [UInt8](repeating: 0, count: uniforms.byteCount)
                scratch.withUnsafeMutableBytes { raw in
                    uniforms.copyBytes(raw.baseAddress!)
                }
                scratch.withUnsafeBytes { raw in
                    encoder.setBytes(
                        raw.baseAddress!,
                        length: uniforms.byteCount,
                        index: 0
                    )
                }
            } else if let binding = try uniformPool.nextBuffer(
                for: uniforms,
                commandBuffer: commandBuffer
            ) {
                encoder.setBuffer(binding.buffer, offset: binding.offset, index: 0)
            }
        }

        // 6. Dispatch with device-appropriate threadgroup sizing
        let threadgroupSize = threadgroupSize(for: pso)
        let gridSize = MTLSize(
            width: destination.width,
            height: destination.height,
            depth: 1
        )
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)

        // 7. Finalize
        encoder.endEncoding()
        encoderEnded = true
    }

    // MARK: - Private helpers

    private static func validateDimensions(
        source: MTLTexture,
        destination: MTLTexture
    ) throws {
        // Destination must have write access — compute kernels write to it.
        guard destination.usage.contains(.shaderWrite) else {
            throw PipelineError.texture(.formatMismatch(
                expected: "destination with .shaderWrite usage",
                got: "usage=\(destination.usage.rawValue)"
            ))
        }

        // Warn (not error) if sizes differ — some kernels deliberately write
        // to different-sized destinations (downsampling, upsampling). But log
        // it for diagnostic clarity.
        if source.width != destination.width || source.height != destination.height {
            DCRLogging.logger.debug(
                "Compute dispatch with asymmetric texture sizes",
                category: "ComputeDispatcher",
                attributes: [
                    "source": "\(source.width)x\(source.height)",
                    "destination": "\(destination.width)x\(destination.height)",
                ]
            )
        }
    }

    /// Choose a threadgroup size suited to the PSO's SIMD characteristics.
    ///
    /// Apple GPUs have a SIMD width of 32. We choose 32×8 = 256 threads per
    /// threadgroup which:
    /// - Fills 8 simdgroups (full warp utilization)
    /// - Leaves register pressure manageable for complex kernels
    /// - Is a well-tested sweet spot used by MPS and Apple sample code
    ///
    /// For kernels with higher register pressure we'd normally clamp to
    /// `maxTotalThreadsPerThreadgroup`, but we skip that optimization for
    /// now and let Metal's compiler surface the issue via PSO creation
    /// failure if it ever arises.
    private static func threadgroupSize(for pso: MTLComputePipelineState) -> MTLSize {
        let w = pso.threadExecutionWidth          // SIMD width (32 on Apple GPUs)
        let maxTotal = pso.maxTotalThreadsPerThreadgroup
        // Aim for w × 8 = 256, but clamp if the PSO says otherwise.
        let target = 8
        let h = min(target, maxTotal / max(w, 1))
        return MTLSize(width: w, height: max(h, 1), depth: 1)
    }
}
