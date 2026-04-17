//
//  Device.swift
//  DCRenderKit
//
//  Wraps the system Metal device with common configuration. Provides a shared
//  default instance and factory methods for dependent resources (command
//  queues, libraries, etc).
//

import Foundation
import Metal

/// A thin wrapper around `MTLDevice` that centralizes device-level state and
/// dependent resources used across the SDK.
///
/// The pipeline and dispatchers typically use `Device.shared`. Tests or
/// consumers with special requirements can construct a `Device` with a
/// custom `MTLDevice`.
///
/// ## Threading
///
/// `Device` is `Sendable` and safe to access from any thread. Its internal
/// state (shared command queue) is protected by a lock.
public final class Device: @unchecked Sendable {

    // MARK: - Shared instance

    /// The default device wrapping the system's default Metal device.
    ///
    /// Crashes with a fatal error if no Metal device is available. This is
    /// deliberate: every platform DCRenderKit supports has Metal, and
    /// attempting to run without one indicates a misconfiguration that
    /// deserves immediate failure.
    ///
    /// For more graceful handling, use `Device.tryShared` instead.
    public static let shared: Device = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError(
                "DCRenderKit: No Metal-capable device available. "
                + "Check that the target platform supports Metal and that "
                + "you're not running in a stripped-down simulator."
            )
        }
        return Device(metalDevice: device)
    }()

    /// Non-crashing variant that returns `nil` when Metal is unavailable.
    /// Prefer this over `shared` when your code path must survive
    /// Metal-less environments (e.g. unit tests on headless CI).
    public static let tryShared: Device? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            DCRLogging.logger.warning(
                "No Metal device available; Device.tryShared is nil",
                category: "Device"
            )
            return nil
        }
        return Device(metalDevice: device)
    }()

    // MARK: - Stored state

    /// The underlying `MTLDevice`.
    public let metalDevice: MTLDevice

    /// Human-readable device name, suitable for logging.
    public var name: String { metalDevice.name }

    /// Whether the device supports unified memory (Apple Silicon / modern iOS).
    /// Affects texture storage mode choices.
    public var hasUnifiedMemory: Bool { metalDevice.hasUnifiedMemory }

    /// Maximum texture width/height supported by this device.
    public var maxTextureDimension: Int {
        // 2D: 16384×16384 on all current Apple GPUs.
        // Conservative value used for boundary checks.
        #if os(macOS)
        return 16384
        #else
        return 16384
        #endif
    }

    private let lock = NSLock()
    private var _commandQueue: MTLCommandQueue?

    // MARK: - Init

    /// Create a `Device` wrapping a specific `MTLDevice`. Most callers should
    /// use `Device.shared` instead.
    public init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
        DCRLogging.logger.info(
            "Device initialized",
            category: "Device",
            attributes: [
                "name": metalDevice.name,
                "unifiedMemory": "\(metalDevice.hasUnifiedMemory)",
            ]
        )
    }

    // MARK: - Command queue

    /// The shared command queue for this device. Lazily constructed on first
    /// access.
    ///
    /// DCRenderKit uses a single queue for the pipeline and its dispatchers.
    /// Consumers can create additional queues by calling `makeCommandQueue()`.
    public var commandQueue: MTLCommandQueue {
        lock.lock()
        defer { lock.unlock() }

        if let queue = _commandQueue {
            return queue
        }

        guard let queue = metalDevice.makeCommandQueue() else {
            // Matches the `Device.shared` contract: failure here indicates
            // a fundamental Metal configuration issue.
            fatalError("DCRenderKit: Failed to create MTLCommandQueue")
        }
        queue.label = "com.dcrenderkit.shared"
        _commandQueue = queue
        return queue
    }

    /// Create a new dedicated command queue. Use this when you need an
    /// independent queue for a specific workload (e.g. video capture).
    public func makeCommandQueue(label: String? = nil) throws -> MTLCommandQueue {
        guard let queue = metalDevice.makeCommandQueue() else {
            throw PipelineError.device(.commandQueueCreationFailed)
        }
        if let label = label {
            queue.label = label
        }
        return queue
    }

    // MARK: - Command buffer

    /// Create a new command buffer from the shared queue.
    ///
    /// For high-throughput scenarios, prefer obtaining buffers via the
    /// `CommandBufferPool` (introduced separately in this round).
    public func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let buffer = commandQueue.makeCommandBuffer() else {
            throw PipelineError.device(.commandBufferCreationFailed)
        }
        return buffer
    }
}
