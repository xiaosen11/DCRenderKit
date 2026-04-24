//
//  CommandBufferPool.swift
//  DCRenderKit
//
//  Pool of `MTLCommandBuffer` objects to limit concurrent in-flight
//  submissions and provide a single-point-of-control for command buffer
//  lifecycle and logging.
//

import Foundation
import Metal

/// Controls the lifecycle of `MTLCommandBuffer` instances used by the
/// pipeline.
///
/// Unlike a traditional object pool (which would hold freed command buffers
/// for reuse), Metal command buffers are one-shot: once committed they can't
/// be reset and reused. This "pool" therefore serves two different purposes:
///
/// 1. **Concurrency limiting** — caps the number of in-flight command
///    buffers via a semaphore, preventing GPU queue overcommit that causes
///    stutters on thermally constrained devices.
///
/// 2. **Label-and-log** — tags every buffer with a caller-supplied label and
///    logs submission/completion events at debug level for diagnostics.
@available(iOS 18.0, *)
public final class CommandBufferPool: @unchecked Sendable {

    // MARK: - Shared instance

    public static let shared = CommandBufferPool(device: Device.shared)

    // MARK: - Configuration

    /// Maximum concurrent in-flight command buffers. When reached, new
    /// requests block until an earlier buffer completes.
    public let maxInFlight: Int

    // MARK: - State

    private let device: Device
    private let semaphore: DispatchSemaphore

    // MARK: - Init

    public init(device: Device, maxInFlight: Int = 4) {
        precondition(maxInFlight > 0, "maxInFlight must be positive")
        self.device = device
        self.maxInFlight = maxInFlight
        self.semaphore = DispatchSemaphore(value: maxInFlight)
    }

    // MARK: - Public API

    /// Obtain a fresh command buffer, blocking until slot is available.
    ///
    /// - Parameter label: Diagnostic label (e.g. "PreviewFrame-\(frameID)").
    /// - Returns: A new, empty `MTLCommandBuffer` from the shared queue.
    /// - Throws: `PipelineError.device(.commandBufferCreationFailed)` if
    ///   Metal fails to allocate.
    public func makeCommandBuffer(label: String? = nil) throws -> MTLCommandBuffer {
        // Throttle to `maxInFlight` concurrent buffers.
        semaphore.wait()

        guard let buffer = device.commandQueue.makeCommandBuffer() else {
            semaphore.signal()  // Don't leak the slot on failure.
            throw PipelineError.device(.commandBufferCreationFailed)
        }

        if let label = label {
            buffer.label = label
        }

        // Release the slot when the buffer completes (success or failure).
        let sema = semaphore
        buffer.addCompletedHandler { _ in
            sema.signal()
        }

        return buffer
    }

    /// Convenience that creates a buffer, runs the given encoding closure,
    /// and commits. Does NOT wait for completion.
    public func enqueue(
        label: String? = nil,
        encoding: (MTLCommandBuffer) throws -> Void
    ) throws {
        let buffer = try makeCommandBuffer(label: label)
        try encoding(buffer)
        buffer.commit()
    }

    /// Convenience that creates, encodes, commits, and waits for completion.
    /// Use this when the caller needs the GPU work to finish before
    /// proceeding (e.g. reading back a texture).
    public func enqueueAndWait(
        label: String? = nil,
        encoding: (MTLCommandBuffer) throws -> Void
    ) throws {
        let buffer = try makeCommandBuffer(label: label)
        try encoding(buffer)
        buffer.commit()
        buffer.waitUntilCompleted()

        if let error = buffer.error {
            throw PipelineError.device(.gpuExecutionFailed(underlying: error))
        }
    }
}
