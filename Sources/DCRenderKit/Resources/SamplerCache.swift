//
//  SamplerCache.swift
//  DCRenderKit
//
//  Caches `MTLSamplerState` instances. Required by render filters and by
//  compute kernels that use `access::sample` access.
//

import Foundation
import Metal

/// Thread-safe cache of `MTLSamplerState` instances keyed by sampler
/// configuration.
///
/// `MTLSamplerState` creation is cheap individually but quickly adds up when
/// hundreds of filters each ask for a sampler every frame. This cache ensures
/// each unique configuration is built once and reused.
@available(iOS 18.0, *)
public final class SamplerCache: @unchecked Sendable {

    // MARK: - Shared instance

    public static let shared = SamplerCache(device: Device.shared)

    // MARK: - State

    private let device: Device
    private let lock = NSLock()
    private var cache: [SamplerConfig: MTLSamplerState] = [:]

    // MARK: - Init

    public init(device: Device) {
        self.device = device
    }

    // MARK: - Public API

    /// Return a `MTLSamplerState` matching the given configuration, creating
    /// and caching on first access.
    public func sampler(for config: SamplerConfig) throws -> MTLSamplerState {
        lock.lock()
        if let cached = cache[config] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = config.minFilter
        descriptor.magFilter = config.magFilter
        descriptor.mipFilter = config.mipFilter
        descriptor.sAddressMode = config.sAddressMode
        descriptor.tAddressMode = config.tAddressMode
        descriptor.rAddressMode = config.rAddressMode
        descriptor.normalizedCoordinates = config.normalizedCoordinates

        guard let sampler = device.metalDevice.makeSamplerState(descriptor: descriptor) else {
            throw PipelineError.resource(.samplerCreationFailed(
                reason: "MTLDevice.makeSamplerState returned nil for config: \(config)"
            ))
        }

        lock.lock()
        if let raced = cache[config] {
            lock.unlock()
            return raced
        }
        cache[config] = sampler
        lock.unlock()
        return sampler
    }

    /// Clear all cached samplers. Primarily for testing.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}

// MARK: - SamplerConfig

/// The subset of `MTLSamplerDescriptor` fields that affect sampler behavior
/// in DCRenderKit's use cases.
@available(iOS 18.0, *)
public struct SamplerConfig: Sendable, Hashable {

    public var minFilter: MTLSamplerMinMagFilter
    public var magFilter: MTLSamplerMinMagFilter
    public var mipFilter: MTLSamplerMipFilter
    public var sAddressMode: MTLSamplerAddressMode
    public var tAddressMode: MTLSamplerAddressMode
    public var rAddressMode: MTLSamplerAddressMode
    public var normalizedCoordinates: Bool

    public init(
        minFilter: MTLSamplerMinMagFilter = .linear,
        magFilter: MTLSamplerMinMagFilter = .linear,
        mipFilter: MTLSamplerMipFilter = .notMipmapped,
        sAddressMode: MTLSamplerAddressMode = .clampToEdge,
        tAddressMode: MTLSamplerAddressMode = .clampToEdge,
        rAddressMode: MTLSamplerAddressMode = .clampToEdge,
        normalizedCoordinates: Bool = true
    ) {
        self.minFilter = minFilter
        self.magFilter = magFilter
        self.mipFilter = mipFilter
        self.sAddressMode = sAddressMode
        self.tAddressMode = tAddressMode
        self.rAddressMode = rAddressMode
        self.normalizedCoordinates = normalizedCoordinates
    }

    /// Bilinear filtering, clamp to edge. The most common choice for
    /// photo editing where we want smooth upsampling without tiling.
    public static let linearClamp = SamplerConfig()

    /// Nearest-neighbor filtering, clamp to edge. Used when pixel-exact
    /// reads are required (e.g. LUT index lookups).
    public static let nearestClamp = SamplerConfig(
        minFilter: .nearest,
        magFilter: .nearest
    )

    /// Bilinear filtering, repeat. Useful for tiled patterns like film grain.
    public static let linearRepeat = SamplerConfig(
        sAddressMode: .repeat,
        tAddressMode: .repeat
    )
}
