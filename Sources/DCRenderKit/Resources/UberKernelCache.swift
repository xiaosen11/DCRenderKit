//
//  UberKernelCache.swift
//  DCRenderKit
//
//  Caches runtime-generated uber-kernel `MTLLibrary` and
//  `MTLComputePipelineState` instances by the deterministic
//  function name `MetalSourceBuilder` assigns. Separate from
//  `PipelineStateCache` (which caches standalone kernels by
//  `ShaderLibrary` lookup) because uber kernels are compiled
//  from runtime-generated source, not resolved from a
//  pre-registered library.
//
//  Cache hit semantics: the same `(source, functionName)` pair
//  always produces the same PSO, so two Nodes that hash to the
//  same uber-kernel name share one compiled library + PSO across
//  their lifetimes. The `MetalSourceBuilder` hashes exclude
//  uniform values, so different slider positions of the same
//  filter also share cache entries — uniforms bind at dispatch.
//

import Foundation
import Metal

/// Thread-safe cache of uber-kernel compilation artifacts.
///
/// Keyed by the deterministic function name produced by
/// `MetalSourceBuilder.uberFunctionName(...)`. Two distinct calls
/// with the same name are assumed to share the same source text;
/// the cache does not verify this because the name is already a
/// hash of every input that affects source generation.
@available(iOS 18.0, *)
internal final class UberKernelCache: @unchecked Sendable {

    /// Default cache used by `ComputeBackend`. Keyed to the shared
    /// Metal device.
    static let shared = UberKernelCache(device: .shared)

    // MARK: - State

    private let device: Device
    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]

    // MARK: - Init

    init(device: Device) {
        self.device = device
    }

    // MARK: - Public API

    /// Return a ready-to-use compute PSO for the given uber kernel,
    /// compiling and caching on first call.
    ///
    /// - Parameters:
    ///   - source: Complete Metal source containing `functionName`.
    ///     On cache miss, this is handed to
    ///     `MTLDevice.makeLibrary(source:options:)`. On cache hit
    ///     the source is ignored — the cached PSO already reflects
    ///     it because the name was derived from a hash of every
    ///     structural input.
    ///   - functionName: Name of the uber kernel's `kernel void`
    ///     entry point, as emitted by `MetalSourceBuilder`.
    /// - Returns: The cached or newly-compiled PSO.
    /// - Throws: `PipelineError.pipelineState(.computeCompileFailed)`
    ///   on Metal library compilation failure;
    ///   `PipelineError.pipelineState(.functionNotFound)` if
    ///   `functionName` does not appear in the compiled library
    ///   (would indicate a builder bug).
    func pipelineState(
        source: String,
        functionName: String
    ) throws -> MTLComputePipelineState {
        // Fast path: PSO already cached.
        lock.lock()
        if let cached = pipelines[functionName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let library = try makeOrFetchLibrary(source: source, functionName: functionName)
        guard let function = library.makeFunction(name: functionName) else {
            throw PipelineError.pipelineState(.functionNotFound(name: functionName))
        }

        let pso: MTLComputePipelineState
        do {
            pso = try device.metalDevice.makeComputePipelineState(function: function)
        } catch {
            throw PipelineError.pipelineState(
                .computeCompileFailed(kernel: functionName, underlying: error)
            )
        }

        // Race-aware store: if two threads compiled the same kernel
        // concurrently, the first winner stays.
        lock.lock()
        if let raceWinner = pipelines[functionName] {
            lock.unlock()
            return raceWinner
        }
        pipelines[functionName] = pso
        lock.unlock()

        DCRLogging.logger.debug(
            "Uber kernel compiled and cached",
            category: "UberKernelCache",
            attributes: ["function": functionName]
        )
        return pso
    }

    /// Drop all cached libraries and PSOs. Primarily for tests.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        libraries.removeAll()
        pipelines.removeAll()
    }

    /// Diagnostic snapshot of how many PSOs are currently cached.
    var cachedPipelineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pipelines.count
    }

    /// `true` if a pipeline named `functionName` is already in the
    /// cache. Used by `ComputeBackend` diagnostic logging to label
    /// each dispatch as a cache hit or miss without touching the
    /// main `pipelineState(source:functionName:)` fast path.
    func containsPipelineState(named functionName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pipelines[functionName] != nil
    }

    // MARK: - Private

    private func makeOrFetchLibrary(
        source: String,
        functionName: String
    ) throws -> MTLLibrary {
        lock.lock()
        if let cached = libraries[functionName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let library: MTLLibrary
        do {
            library = try device.metalDevice.makeLibrary(source: source, options: nil)
        } catch {
            throw PipelineError.pipelineState(
                .computeCompileFailed(kernel: functionName, underlying: error)
            )
        }

        lock.lock()
        if let raceWinner = libraries[functionName] {
            lock.unlock()
            return raceWinner
        }
        libraries[functionName] = library
        lock.unlock()
        return library
    }
}
