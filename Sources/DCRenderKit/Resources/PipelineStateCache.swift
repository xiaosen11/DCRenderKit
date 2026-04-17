//
//  PipelineStateCache.swift
//  DCRenderKit
//
//  Caches `MTLComputePipelineState` and `MTLRenderPipelineState` by kernel
//  name and render configuration. PSO compilation is the single most expensive
//  Metal operation (10-100ms per kernel); caching is essential for 30-60fps
//  pipelines.
//

import Foundation
import Metal

/// Thread-safe cache for compute and render pipeline state objects.
///
/// ## Why this exists
///
/// `MTLDevice.makeComputePipelineState(function:)` and its render sibling
/// compile Metal IR to GPU-specific machine code on first call. For a
/// non-trivial kernel this takes 10-100ms on first access — unacceptable
/// inside a 30fps frame loop. This cache reuses compiled PSOs across
/// dispatches.
///
/// ## Caching scheme
///
/// - **Compute PSOs** are keyed by kernel function name alone (the function
///   fully determines the pipeline).
/// - **Render PSOs** are keyed by a composite of `(vertex, fragment,
///   colorPixelFormat, blendDescriptor, rasterSampleCount)`. Two filters
///   using the same shaders but different blend modes get different PSOs.
public final class PipelineStateCache: @unchecked Sendable {

    // MARK: - Shared instance

    /// The default cache used by the SDK's dispatchers. Keyed to the shared
    /// `Device`. Tests can construct their own cache with a custom `Device`.
    public static let shared = PipelineStateCache(device: Device.shared)

    // MARK: - Stored state

    private let device: Device
    private let lock = NSLock()
    private var computeCache: [String: MTLComputePipelineState] = [:]
    private var renderCache: [RenderPSOKey: MTLRenderPipelineState] = [:]

    // MARK: - Init

    public init(device: Device) {
        self.device = device
    }

    // MARK: - Compute PSO

    /// Return a `MTLComputePipelineState` for the given kernel function name,
    /// compiling and caching it on first access.
    ///
    /// - Parameter kernelName: Name of a kernel function in any registered
    ///   Metal library.
    /// - Returns: The cached or newly-created pipeline state.
    /// - Throws: `PipelineError.pipelineState(.computeCompileFailed)` on
    ///   compilation failure or `.functionNotFound` if the kernel name does
    ///   not resolve.
    public func computePipelineState(
        forKernel kernelName: String
    ) throws -> MTLComputePipelineState {
        // Fast path: cache hit without holding the lock for compilation.
        lock.lock()
        if let cached = computeCache[kernelName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Resolve function (may itself be cached by ShaderLibrary).
        let function = try ShaderLibrary.shared.function(named: kernelName)

        // Compile the PSO. This is the expensive step.
        let pso: MTLComputePipelineState
        do {
            pso = try device.metalDevice.makeComputePipelineState(function: function)
        } catch {
            throw PipelineError.pipelineState(
                .computeCompileFailed(kernel: kernelName, underlying: error)
            )
        }

        // Store in cache. If another thread raced us to compile the same
        // kernel, their result wins (both are equivalent).
        lock.lock()
        if let racedWinner = computeCache[kernelName] {
            lock.unlock()
            return racedWinner
        }
        computeCache[kernelName] = pso
        lock.unlock()

        DCRLogging.logger.debug(
            "Compute PSO compiled and cached",
            category: "PipelineStateCache",
            attributes: ["kernel": kernelName]
        )
        return pso
    }

    // MARK: - Render PSO

    /// Return a `MTLRenderPipelineState` for the given descriptor, compiling
    /// and caching on first access.
    ///
    /// - Parameter descriptor: A `RenderPSODescriptor` capturing all variables
    ///   that affect PSO compilation.
    /// - Returns: The cached or newly-created pipeline state.
    /// - Throws: `PipelineError.pipelineState(.renderCompileFailed)` on
    ///   compilation failure.
    public func renderPipelineState(
        for descriptor: RenderPSODescriptor
    ) throws -> MTLRenderPipelineState {
        let key = descriptor.cacheKey

        lock.lock()
        if let cached = renderCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let vertexFunction = try ShaderLibrary.shared.function(named: descriptor.vertexFunction)
        let fragmentFunction = try ShaderLibrary.shared.function(named: descriptor.fragmentFunction)

        let mtlDesc = MTLRenderPipelineDescriptor()
        mtlDesc.vertexFunction = vertexFunction
        mtlDesc.fragmentFunction = fragmentFunction
        mtlDesc.rasterSampleCount = descriptor.rasterSampleCount

        let attachment = mtlDesc.colorAttachments[0]!
        attachment.pixelFormat = descriptor.colorPixelFormat
        attachment.isBlendingEnabled = descriptor.blend.isEnabled
        attachment.rgbBlendOperation = descriptor.blend.rgbOperation
        attachment.alphaBlendOperation = descriptor.blend.alphaOperation
        attachment.sourceRGBBlendFactor = descriptor.blend.sourceRGB
        attachment.destinationRGBBlendFactor = descriptor.blend.destinationRGB
        attachment.sourceAlphaBlendFactor = descriptor.blend.sourceAlpha
        attachment.destinationAlphaBlendFactor = descriptor.blend.destinationAlpha

        let pso: MTLRenderPipelineState
        do {
            pso = try device.metalDevice.makeRenderPipelineState(descriptor: mtlDesc)
        } catch {
            throw PipelineError.pipelineState(.renderCompileFailed(
                vertex: descriptor.vertexFunction,
                fragment: descriptor.fragmentFunction,
                underlying: error
            ))
        }

        lock.lock()
        if let racedWinner = renderCache[key] {
            lock.unlock()
            return racedWinner
        }
        renderCache[key] = pso
        lock.unlock()

        DCRLogging.logger.debug(
            "Render PSO compiled and cached",
            category: "PipelineStateCache",
            attributes: [
                "vertex": descriptor.vertexFunction,
                "fragment": descriptor.fragmentFunction,
            ]
        )
        return pso
    }

    // MARK: - Diagnostics

    /// Remove all cached PSOs. Primarily for testing.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        computeCache.removeAll()
        renderCache.removeAll()
    }

    /// Number of compiled compute PSOs currently in the cache.
    public var computeCacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return computeCache.count
    }

    /// Number of compiled render PSOs currently in the cache.
    public var renderCacheCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return renderCache.count
    }
}

// MARK: - RenderPSODescriptor

/// Describes everything that affects render PSO compilation. The cache uses
/// this struct's fields to determine equivalence.
///
/// Use one of the factory methods on `RenderPSODescriptor` for common
/// configurations (opaque quad, alpha-blended overlay, additive light leak,
/// etc.) rather than constructing directly.
public struct RenderPSODescriptor: Sendable, Hashable {

    public var vertexFunction: String
    public var fragmentFunction: String
    public var colorPixelFormat: MTLPixelFormat
    public var blend: BlendConfig
    public var rasterSampleCount: Int

    public init(
        vertexFunction: String,
        fragmentFunction: String,
        colorPixelFormat: MTLPixelFormat = .rgba16Float,
        blend: BlendConfig = .opaque,
        rasterSampleCount: Int = 1
    ) {
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction
        self.colorPixelFormat = colorPixelFormat
        self.blend = blend
        self.rasterSampleCount = rasterSampleCount
    }

    fileprivate var cacheKey: RenderPSOKey {
        RenderPSOKey(
            vertex: vertexFunction,
            fragment: fragmentFunction,
            pixelFormat: colorPixelFormat.rawValue,
            blend: blend,
            samples: rasterSampleCount
        )
    }
}

// MARK: - BlendConfig

/// Color attachment blending configuration. Covers the blending modes we
/// actually need for stickers, glows, and masked composites.
public struct BlendConfig: Sendable, Hashable {

    public var isEnabled: Bool
    public var rgbOperation: MTLBlendOperation
    public var alphaOperation: MTLBlendOperation
    public var sourceRGB: MTLBlendFactor
    public var destinationRGB: MTLBlendFactor
    public var sourceAlpha: MTLBlendFactor
    public var destinationAlpha: MTLBlendFactor

    public init(
        isEnabled: Bool,
        rgbOperation: MTLBlendOperation = .add,
        alphaOperation: MTLBlendOperation = .add,
        sourceRGB: MTLBlendFactor = .one,
        destinationRGB: MTLBlendFactor = .zero,
        sourceAlpha: MTLBlendFactor = .one,
        destinationAlpha: MTLBlendFactor = .zero
    ) {
        self.isEnabled = isEnabled
        self.rgbOperation = rgbOperation
        self.alphaOperation = alphaOperation
        self.sourceRGB = sourceRGB
        self.destinationRGB = destinationRGB
        self.sourceAlpha = sourceAlpha
        self.destinationAlpha = destinationAlpha
    }

    /// No blending. Output replaces destination entirely.
    public static let opaque = BlendConfig(isEnabled: false)

    /// Standard source-over alpha compositing (unpremultiplied source).
    /// `dest = source × source.a + dest × (1 - source.a)`
    public static let alphaBlend = BlendConfig(
        isEnabled: true,
        sourceRGB: .sourceAlpha,
        destinationRGB: .oneMinusSourceAlpha,
        sourceAlpha: .one,
        destinationAlpha: .oneMinusSourceAlpha
    )

    /// Premultiplied source-over alpha compositing.
    /// `dest = source + dest × (1 - source.a)`
    public static let premultipliedAlphaBlend = BlendConfig(
        isEnabled: true,
        sourceRGB: .one,
        destinationRGB: .oneMinusSourceAlpha,
        sourceAlpha: .one,
        destinationAlpha: .oneMinusSourceAlpha
    )

    /// Additive blending. Useful for light leaks, lens flares, additive glows.
    /// `dest = source + dest`
    public static let additive = BlendConfig(
        isEnabled: true,
        sourceRGB: .one,
        destinationRGB: .one,
        sourceAlpha: .one,
        destinationAlpha: .one
    )
}

// MARK: - Internal key

/// Opaque, hashable key used for the render PSO cache dictionary.
private struct RenderPSOKey: Hashable {
    let vertex: String
    let fragment: String
    let pixelFormat: UInt
    let blend: BlendConfig
    let samples: Int
}
