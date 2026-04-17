//
//  UniformBufferPool.swift
//  DCRenderKit
//
//  Command-buffer-fenced pool of `MTLBuffer` instances for filter uniforms.
//  Safe for unlimited dispatches per command buffer — the pool grows when
//  its free slots are exhausted, and releases reservations on command
//  buffer completion.
//

import Foundation
import Metal

/// Command-buffer-fenced pool of `MTLBuffer` instances for filter uniforms.
///
/// ## Scope
///
/// In the current pipeline, this pool only carries uniforms **larger than
/// 4 KB**. `ComputeDispatcher` and `RenderDispatcher` prefer Metal's
/// `setBytes` / `setVertexBytes` / `setFragmentBytes` for small payloads
/// (covers every filter DCRenderKit ships — none exceed 64 bytes). The
/// pool remains for the rare large-uniform case (hefty lookup tables,
/// long coefficient arrays, custom consumer filters).
///
/// ## Correctness model
///
/// Each buffer in the pool carries a *reservation* — the command buffer
/// currently consuming it. `nextBuffer(for:commandBuffer:)` never returns
/// a buffer that is already reserved, so a single command buffer with
/// `N` large-uniform dispatches gets `N` distinct backing stores. When
/// the command buffer completes (we install exactly one completion
/// handler per command buffer on first acquisition), all its
/// reservations release and the buffers return to the free list.
///
/// If every slot is reserved, the pool grows by one buffer (bounded by
/// `maxBuffers`) rather than risk silently overwriting in-flight data.
/// At the cap, callers fall back to a one-off allocation.
///
/// ## Why not a naive ring
///
/// A ring of `N` buffers without fence tracking corrupts state whenever
/// a single command buffer encodes more than `N` large-uniform dispatches
/// — the ring wraps, and later binds overwrite earlier binds' data still
/// pending GPU execution. That was the original design of this class and
/// was fixed here before it could surface in a consumer's long filter
/// chain.
public final class UniformBufferPool: @unchecked Sendable {

    // MARK: - Shared instance

    public static let shared = UniformBufferPool(device: Device.shared)

    // MARK: - Configuration

    /// Initial number of pre-allocated buffers. The pool grows on demand
    /// up to `maxBuffers`; this is just the starting capacity.
    public let initialCapacity: Int

    /// Hard ceiling on the pool size. Once reached, additional uniform
    /// requests that can't find a free buffer fall back to one-off
    /// allocation instead of growing further. Default 64 is well beyond
    /// any realistic single-frame filter count.
    public let maxBuffers: Int

    /// Size of each pooled buffer in bytes. Uniforms larger than this
    /// go through the one-off path.
    public let bufferSize: Int

    // MARK: - State

    private struct Slot {
        let buffer: MTLBuffer
        /// The command buffer currently consuming this slot, identified
        /// by `ObjectIdentifier`. `nil` = free.
        var reservation: ObjectIdentifier?
    }

    private let device: Device
    private let lock = NSLock()
    private var slots: [Slot] = []

    /// Command buffers we've already installed a completion handler on.
    /// Prevents double-registration if the same command buffer makes
    /// multiple uniform requests.
    private var handlersAttached: Set<ObjectIdentifier> = []

    // MARK: - Init

    /// Create a pool. `initialCapacity` buffers are pre-allocated;
    /// the pool grows on demand up to `maxBuffers`.
    public init(
        device: Device,
        capacity: Int = 3,
        maxBuffers: Int = 64,
        bufferSize: Int = 4096
    ) {
        precondition(capacity > 0, "UniformBufferPool capacity must be positive")
        precondition(maxBuffers >= capacity, "maxBuffers must be >= capacity")
        precondition(bufferSize > 0, "UniformBufferPool bufferSize must be positive")

        self.device = device
        self.initialCapacity = capacity
        self.maxBuffers = maxBuffers
        self.bufferSize = bufferSize

        let options: MTLResourceOptions = [.storageModeShared, .cpuCacheModeWriteCombined]

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
                break
            }
            buffer.label = "com.dcrenderkit.uniforms.\(slots.count)"
            slots.append(Slot(buffer: buffer, reservation: nil))
        }

        DCRLogging.logger.info(
            "UniformBufferPool initialized",
            category: "UniformBufferPool",
            attributes: [
                "initialCapacity": "\(slots.count)",
                "maxBuffers": "\(maxBuffers)",
                "bufferSize": "\(bufferSize)",
            ]
        )
    }

    // MARK: - Public API

    /// Obtain a buffer reserved for `commandBuffer`'s lifetime, populated
    /// from `uniforms`.
    ///
    /// The reservation releases automatically when `commandBuffer`
    /// completes. Multiple requests against the same `commandBuffer`
    /// return distinct buffers, so a chain of `N` dispatches in one
    /// command buffer can bind `N` distinct uniform payloads without
    /// overwriting each other.
    ///
    /// - Parameters:
    ///   - uniforms: Parameter struct whose bytes to copy in.
    ///   - commandBuffer: The consuming command buffer. The pool
    ///     installs at most one completion handler per command buffer.
    /// - Returns: `(buffer, offset)` ready to bind, or `nil` for an
    ///   empty `uniforms` payload (nothing to bind).
    /// - Throws: `PipelineError.resource(.uniformBufferAllocationFailed)`
    ///   if a one-off fallback allocation fails.
    public func nextBuffer(
        for uniforms: FilterUniforms,
        commandBuffer: MTLCommandBuffer
    ) throws -> (buffer: MTLBuffer, offset: Int)? {
        guard uniforms.byteCount > 0 else { return nil }
        guard uniforms.byteCount <= bufferSize else {
            // Larger than a pooled buffer; always one-off.
            return try allocateOneOff(uniforms: uniforms)
        }

        let cbID = ObjectIdentifier(commandBuffer)

        lock.lock()

        // Install a completion handler on first acquisition for this
        // command buffer so all its reservations release together.
        let needsHandler = !handlersAttached.contains(cbID)
        if needsHandler {
            handlersAttached.insert(cbID)
        }

        // Find a free slot …
        var slotIndex = slots.firstIndex { $0.reservation == nil }

        // … or grow the pool if we're below the cap …
        if slotIndex == nil, slots.count < maxBuffers {
            if let newBuffer = device.metalDevice.makeBuffer(
                length: bufferSize,
                options: [.storageModeShared, .cpuCacheModeWriteCombined]
            ) {
                newBuffer.label = "com.dcrenderkit.uniforms.\(slots.count)"
                slots.append(Slot(buffer: newBuffer, reservation: nil))
                slotIndex = slots.count - 1
                DCRLogging.logger.debug(
                    "UniformBufferPool grew",
                    category: "UniformBufferPool",
                    attributes: ["slotCount": "\(slots.count)"]
                )
            }
        }

        guard let idx = slotIndex else {
            // At the cap and every slot busy — fall back to one-off.
            lock.unlock()
            DCRLogging.logger.warning(
                "UniformBufferPool at cap, falling back to one-off allocation",
                category: "UniformBufferPool",
                attributes: ["cap": "\(maxBuffers)"]
            )
            return try allocateOneOff(uniforms: uniforms)
        }

        slots[idx].reservation = cbID
        let buffer = slots[idx].buffer
        lock.unlock()

        uniforms.copyBytes(buffer.contents())

        if needsHandler {
            // Install handler outside the lock. Metal invokes it on an
            // unspecified thread; the release function re-acquires the
            // lock internally.
            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.releaseReservations(for: cbID)
            }
        }

        return (buffer, 0)
    }

    // MARK: - Diagnostics

    /// Snapshot of the current slot count (including any growth beyond
    /// `initialCapacity`). Intended for tests and debugging.
    public var currentSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.count
    }

    /// Snapshot of how many slots are currently reserved. Tests can use
    /// this to verify reservations release after command-buffer
    /// completion.
    public var reservedSlotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return slots.filter { $0.reservation != nil }.count
    }

    // MARK: - Private

    private func releaseReservations(for cbID: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<slots.count where slots[i].reservation == cbID {
            slots[i].reservation = nil
        }
        handlersAttached.remove(cbID)
    }

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
