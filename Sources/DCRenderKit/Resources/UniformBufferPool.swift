//
//  UniformBufferPool.swift
//  DCRenderKit
//
//  Pre-allocated ring buffer for uniform (parameter) buffers. Eliminates the
//  per-frame allocation cost that comes from calling
//  `device.makeBuffer(bytes:)` inside dispatchers, and avoids CPU-GPU
//  synchronization stalls by rotating through multiple buffers.
//

import Foundation
import Metal

/// Ring-allocated pool of `MTLBuffer` instances for filter uniforms.
///
/// ## Why this exists
///
/// Harbeth's design calls `MTLCommandEncoder.setBytes(_:length:index:)` on
/// every filter dispatch, which allocates a transient buffer behind the
/// scenes. For a 30fps pipeline with 10 filters this is 300 allocations per
/// second — measurable CPU overhead and GC pressure.
///
/// `UniformBufferPool` pre-allocates a fixed set of buffers and rotates
/// through them. Each frame's uniforms are written into the next buffer in
/// the ring; by the time we wrap around to that buffer again (after
/// `capacity` frames), the GPU is guaranteed to be done with it.
///
/// ## Triple buffering
///
/// Default capacity is 3 (triple buffering), matching typical Metal
/// double/triple-buffer conventions. This eliminates CPU-GPU contention
/// without wasting memory.
public final class UniformBufferPool: @unchecked Sendable {

    // MARK: - Shared instance

    public static let shared = UniformBufferPool(device: Device.shared)

    // MARK: - Configuration

    /// Number of buffers in the rotation. 3 is the default (triple buffering).
    public let capacity: Int

    /// Size of each buffer in bytes. Uniforms larger than this fall back to
    /// a temporary allocation.
    public let bufferSize: Int

    // MARK: - State

    private let device: Device
    private let lock = NSLock()
    private var buffers: [MTLBuffer] = []
    private var nextIndex: Int = 0

    // MARK: - Init

    /// Create a pool with the given capacity (default 3) and buffer size
    /// (default 4 KB — enough for even the most parameter-heavy filters).
    public init(device: Device, capacity: Int = 3, bufferSize: Int = 4096) {
        precondition(capacity > 0, "UniformBufferPool capacity must be positive")
        precondition(bufferSize > 0, "UniformBufferPool bufferSize must be positive")

        self.device = device
        self.capacity = capacity
        self.bufferSize = bufferSize

        // Pre-allocate all buffers so the first frame doesn't pay the cost.
        // Storage mode .shared for iOS (unified memory) and .managed on macOS.
        #if os(iOS) || targetEnvironment(macCatalyst)
        let options: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        #else
        let options: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]
        #endif

        for _ in 0..<capacity {
            guard let buffer = device.metalDevice.makeBuffer(
                length: bufferSize,
                options: options
            ) else {
                DCRLogging.logger.fault(
                    "Failed to pre-allocate uniform buffer",
                    category: "UniformBufferPool",
                    attributes: ["bufferSize": "\(bufferSize)"]
                )
                // Continue with fewer buffers rather than crashing.
                break
            }
            buffer.label = "com.dcrenderkit.uniforms.\(buffers.count)"
            buffers.append(buffer)
        }

        DCRLogging.logger.info(
            "UniformBufferPool initialized",
            category: "UniformBufferPool",
            attributes: [
                "capacity": "\(buffers.count)",
                "bufferSize": "\(bufferSize)",
            ]
        )
    }

    // MARK: - Public API

    /// Obtain the next buffer in the ring and populate it from `uniforms`.
    ///
    /// - Parameter uniforms: The `FilterUniforms` whose bytes to copy.
    /// - Returns: A `(buffer, offset)` pair ready to bind to a Metal
    ///   encoder. Returns `nil` if `uniforms` is empty (no binding needed).
    /// - Throws: `PipelineError.resource(.uniformBufferAllocationFailed)` if
    ///   `uniforms.byteCount > bufferSize` and fallback allocation fails.
    public func nextBuffer(for uniforms: FilterUniforms) throws -> (buffer: MTLBuffer, offset: Int)? {
        guard uniforms.byteCount > 0 else { return nil }

        if uniforms.byteCount > bufferSize {
            // Rare: filter has unusually large uniforms. Allocate one-off.
            return try allocateOneOff(uniforms: uniforms)
        }

        lock.lock()
        guard !buffers.isEmpty else {
            lock.unlock()
            return try allocateOneOff(uniforms: uniforms)
        }
        let buffer = buffers[nextIndex]
        nextIndex = (nextIndex + 1) % buffers.count
        lock.unlock()

        uniforms.copyBytes(buffer.contents())
        return (buffer, 0)
    }

    // MARK: - Private

    private func allocateOneOff(uniforms: FilterUniforms) throws -> (buffer: MTLBuffer, offset: Int) {
        guard let buffer = device.metalDevice.makeBuffer(
            length: uniforms.byteCount,
            options: .storageModeShared
        ) else {
            throw PipelineError.resource(
                .uniformBufferAllocationFailed(requestedBytes: uniforms.byteCount)
            )
        }
        buffer.label = "com.dcrenderkit.uniforms.oneoff"
        uniforms.copyBytes(buffer.contents())
        return (buffer, 0)
    }
}
