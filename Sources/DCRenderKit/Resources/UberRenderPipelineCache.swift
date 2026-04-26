//
//  UberRenderPipelineCache.swift
//  DCRenderKit
//
//  Phase 7 fragment-pipeline analogue of `UberKernelCache`.
//  Caches the runtime-compiled `MTLLibrary` and
//  `MTLRenderPipelineState` for each fused-cluster fragment shader
//  the codegen emits, keyed by the deterministic
//  `(vertexFunction, fragmentFunction)` pair `MetalSourceBuilder`
//  produces.
//
//  Render PSOs are dimensioned by their colour-attachment pixel
//  format, so a cache key includes that format alongside the
//  function names — different intermediate formats yield distinct
//  PSOs even when the fragment shader source is identical.
//

import Foundation
import Metal

/// Thread-safe cache of fragment-pipeline compilation artifacts.
///
/// The render path needs both an `MTLLibrary` (compiled from the
/// source `MetalSourceBuilder.buildFragmentClusterPipeline` emits)
/// and an `MTLRenderPipelineState` keyed by the colour-attachment
/// pixel format. Keeping libraries cached separately avoids
/// re-compiling Metal source for each new attachment-format
/// permutation; PSOs are cached by the full key including format.
@available(iOS 18.0, *)
internal final class UberRenderPipelineCache: @unchecked Sendable {

    /// Default cache used by `RenderBackend`. Bound to `Device.shared`.
    static let shared = UberRenderPipelineCache(device: .shared)

    // MARK: - Cache key

    /// Uniquely identifies a render PSO. Two clusters that codegen
    /// to the same fragment function but target different attachment
    /// formats need separate PSOs — reflected by the `pixelFormat`
    /// in this key.
    struct Key: Hashable, Sendable {
        let vertexFunction: String
        let fragmentFunction: String
        let pixelFormat: MTLPixelFormat
    }

    // MARK: - State

    private let device: Device
    private let lock = NSLock()
    private var libraries: [String: MTLLibrary] = [:]   // keyed by fragmentFunction
    private var pipelines: [Key: MTLRenderPipelineState] = [:]

    init(device: Device) {
        self.device = device
    }

    // MARK: - Public API

    /// Return a ready-to-use render PSO for the given vertex /
    /// fragment pair. Compiles the source on first call; subsequent
    /// calls share the cached `MTLLibrary` and `MTLRenderPipelineState`.
    ///
    /// - Parameters:
    ///   - source: Complete Metal source containing both the
    ///     `vertex` declaration named `key.vertexFunction` and the
    ///     `fragment` declaration named `key.fragmentFunction`.
    ///   - key: Function-pair + colour-attachment format identifier.
    /// - Throws: `PipelineError.pipelineState(.computeCompileFailed)`
    ///   on Metal library compilation failure;
    ///   `PipelineError.pipelineState(.functionNotFound)` if either
    ///   named function is missing from the compiled library.
    func pipelineState(
        source: String,
        key: Key
    ) throws -> MTLRenderPipelineState {
        // Fast path: PSO cached.
        lock.lock()
        if let cached = pipelines[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let library = try makeOrFetchLibrary(
            source: source,
            keyName: key.fragmentFunction
        )
        guard let vertexFn = library.makeFunction(name: key.vertexFunction) else {
            throw PipelineError.pipelineState(.functionNotFound(name: key.vertexFunction))
        }
        guard let fragmentFn = library.makeFunction(name: key.fragmentFunction) else {
            throw PipelineError.pipelineState(.functionNotFound(name: key.fragmentFunction))
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "DCR.Fusion.Render.\(key.fragmentFunction)"
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = key.pixelFormat
        // Programmable blending is enabled when chained-draw routing
        // (Phase 8) reads the attachment via `[[color(0)]]`. The
        // cluster fragment in Phase 7 doesn't read the attachment —
        // it samples the source texture — so blending stays default
        // (off / replace).

        let pso: MTLRenderPipelineState
        do {
            pso = try device.metalDevice.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw PipelineError.pipelineState(
                .computeCompileFailed(kernel: key.fragmentFunction, underlying: error)
            )
        }

        lock.lock()
        if let raceWinner = pipelines[key] {
            lock.unlock()
            return raceWinner
        }
        pipelines[key] = pso
        lock.unlock()

        DCRLogging.logger.debug(
            "Render uber PSO compiled and cached",
            category: "UberRenderPipelineCache",
            attributes: [
                "vertex": key.vertexFunction,
                "fragment": key.fragmentFunction,
                "format": "\(key.pixelFormat.rawValue)",
            ]
        )
        return pso
    }

    /// Drop all cached libraries and PSOs. Tests use this to
    /// observe per-test compilation deltas.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        libraries.removeAll()
        pipelines.removeAll()
    }

    /// Diagnostic snapshot: how many `(vertex, fragment, pixelFormat)`
    /// PSOs are currently cached.
    var cachedPipelineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pipelines.count
    }

    /// `true` if a PSO matching `key` is already cached. Used by
    /// `RenderBackend` diagnostic logging to label dispatches as
    /// hits / misses without touching the fast path.
    func containsPipelineState(forKey key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pipelines[key] != nil
    }

    // MARK: - Private

    private func makeOrFetchLibrary(
        source: String,
        keyName: String
    ) throws -> MTLLibrary {
        lock.lock()
        if let cached = libraries[keyName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let library: MTLLibrary
        do {
            library = try device.metalDevice.makeLibrary(source: source, options: nil)
        } catch {
            throw PipelineError.pipelineState(
                .computeCompileFailed(kernel: keyName, underlying: error)
            )
        }

        lock.lock()
        if let raceWinner = libraries[keyName] {
            lock.unlock()
            return raceWinner
        }
        libraries[keyName] = library
        lock.unlock()
        return library
    }
}
