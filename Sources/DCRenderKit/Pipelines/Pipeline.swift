//
//  Pipeline.swift
//  DCRenderKit
//
//  Top-level user-facing API. Composes TextureLoader, FilterGraphOptimizer,
//  MultiPassExecutor, and the dispatchers into a single `output()` call
//  that business code interacts with.
//

import Foundation
import Metal

/// The primary filter chain execution entry point.
///
/// ## Minimal usage
///
/// ```swift
/// let pipeline = Pipeline(input: .uiImage(myImage), steps: [
///     .single(ExposureFilter(exposure: 20)),
///     .multi(SoftGlowFilter(strength: 30)),
///     .single(LUT3DFilter(preset: .jade)),
/// ])
/// let resultTexture = try await pipeline.output()
/// ```
///
/// ## Execution model
///
/// 1. `source` resolves to an `MTLTexture` via `TextureLoader`.
/// 2. `steps` passes through `FilterGraphOptimizer` (passthrough in Phase 1;
///    fusion in Phase 2).
/// 3. For each step, the pipeline allocates a destination texture from
///    `TexturePool` and dispatches the appropriate backend:
///    - `.single(filter)` → `ComputeDispatcher` (or in the future a
///      render path for filters that surface a render-specific method)
///    - `.multi(filter)` → `MultiPassExecutor`
/// 4. The previous step's output becomes the next step's input; intermediate
///    textures are returned to the pool as soon as they're consumed.
/// 5. `commandBuffer` is committed once all encoding is complete. The
///    async variant awaits GPU completion via `addCompletedHandler`; the
///    sync variant uses `waitUntilCompleted`.
///
/// ## Thread safety
///
/// A single `Pipeline` instance is not safe to call concurrently from
/// multiple threads (its internal texture allocations would race).
/// Multiple `Pipeline` instances can run concurrently — they share the
/// global pools but those are internally thread-safe.
public final class Pipeline: @unchecked Sendable {

    // MARK: - Input

    /// The source of pixels to feed into the filter chain.
    public let source: PipelineInput

    /// The filter chain, in execution order.
    public var steps: [AnyFilter]

    // MARK: - Configuration

    /// Optimization strategy applied to `steps` before execution.
    /// Defaults to the standard optimizer (passthrough in Phase 1).
    public var optimizer: FilterGraphOptimizer

    /// Pixel format of intermediate textures between filters.
    ///
    /// Default is `.rgba16Float` which is the right choice for commercial-
    /// grade precision: eliminates the per-filter 8-bit quantization that
    /// accumulates visible banding in long chains. Set this to
    /// `.bgra8Unorm` only if memory pressure demands it and you've
    /// verified the resulting banding is acceptable for your content.
    public var intermediatePixelFormat: MTLPixelFormat

    // MARK: - Dependencies (injectable for tests)

    internal let device: Device
    internal let textureLoader: TextureLoader
    internal let psoCache: PipelineStateCache
    internal let uniformPool: UniformBufferPool
    internal let samplerCache: SamplerCache
    internal let texturePool: TexturePool
    internal let commandBufferPool: CommandBufferPool

    // MARK: - Init

    /// Create a pipeline bound to the default (shared) resource instances.
    public init(
        input: PipelineInput,
        steps: [AnyFilter] = []
    ) {
        self.source = input
        self.steps = steps
        self.optimizer = FilterGraphOptimizer()
        self.intermediatePixelFormat = .rgba16Float
        self.device = .shared
        self.textureLoader = .shared
        self.psoCache = .shared
        self.uniformPool = .shared
        self.samplerCache = .shared
        self.texturePool = .shared
        self.commandBufferPool = .shared
    }

    /// Create a pipeline with fully-specified dependencies. Primarily for
    /// tests that need isolated pools.
    public init(
        input: PipelineInput,
        steps: [AnyFilter],
        optimizer: FilterGraphOptimizer = FilterGraphOptimizer(),
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float,
        device: Device,
        textureLoader: TextureLoader,
        psoCache: PipelineStateCache,
        uniformPool: UniformBufferPool,
        samplerCache: SamplerCache,
        texturePool: TexturePool,
        commandBufferPool: CommandBufferPool
    ) {
        self.source = input
        self.steps = steps
        self.optimizer = optimizer
        self.intermediatePixelFormat = intermediatePixelFormat
        self.device = device
        self.textureLoader = textureLoader
        self.psoCache = psoCache
        self.uniformPool = uniformPool
        self.samplerCache = samplerCache
        self.texturePool = texturePool
        self.commandBufferPool = commandBufferPool
    }

    // MARK: - Public execution API (sync)

    /// Execute the filter chain and return the resulting texture.
    /// Blocks until the GPU finishes.
    ///
    /// Prefer `output()` (async) for production code. This sync variant
    /// exists primarily for tests and tools that need deterministic
    /// completion semantics.
    public func outputSync() throws -> MTLTexture {
        let (commandBuffer, finalTexture) = try encodeAll()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error {
            throw PipelineError.device(.gpuExecutionFailed(underlying: err))
        }
        return finalTexture
    }

    /// Encode the filter chain into an externally-managed command buffer.
    ///
    /// Unlike `outputSync()` / `output()`, this variant does **not**
    /// allocate, commit, or wait on the command buffer — the caller
    /// retains full control. This is the integration point for real-time
    /// renderers (MTKView.draw, video frame pipelines) that want to
    /// batch the filter chain's dispatches together with the caller's
    /// own blit / present / additional encoders into a single command
    /// buffer — eliminating the extra GPU submission that a separate
    /// `outputSync` call would incur.
    ///
    /// The returned `MTLTexture` is the final output (in the pipeline's
    /// `intermediatePixelFormat`, by default `rgba16Float`). If you need
    /// the result in a specific format / size — typically "write into my
    /// drawable for presentation" — call `encode(into:writingTo:)` instead,
    /// which does format conversion and scaling inside the SDK.
    ///
    /// - Parameter commandBuffer: The command buffer to encode into.
    ///   The caller is responsible for `commit()` and presentation.
    /// - Returns: The final output texture produced by the chain.
    /// - Throws: Texture resolution, PSO, or encoder errors.
    public func encode(into commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let sourceTexture = try source.resolve(using: textureLoader)
        let optimizedSteps = optimizer.optimize(steps)

        guard !optimizedSteps.isEmpty else {
            return sourceTexture
        }

        var currentInput = sourceTexture
        var finalOutput: MTLTexture?
        var pendingEnqueue: [MTLTexture] = []

        for (index, step) in optimizedSteps.enumerated() {
            let isLastStep = (index == optimizedSteps.count - 1)
            let output = try executeStep(
                step,
                sourceTexture: currentInput,
                commandBuffer: commandBuffer
            )

            if currentInput !== sourceTexture, currentInput !== output {
                pendingEnqueue.append(currentInput)
            }

            currentInput = output
            if isLastStep {
                finalOutput = output
            }
        }

        scheduleDeferredEnqueue(
            textures: pendingEnqueue,
            pool: texturePool,
            commandBuffer: commandBuffer
        )

        return finalOutput ?? sourceTexture
    }

    /// Encode the filter chain into `commandBuffer`, writing the final
    /// result into `destination`.
    ///
    /// This is the presentation-path API. The destination can be **any**
    /// texture — typically a `CAMetalDrawable.texture` (BGRA8Unorm) for
    /// on-screen preview, or a caller-allocated video frame buffer. The
    /// SDK handles both:
    ///
    /// - **Format conversion**: chain outputs live in
    ///   `intermediatePixelFormat` (float precision between stages). The
    ///   destination can be any pixel format — the conversion happens
    ///   inside the last encoded pass.
    /// - **Size reconciliation**: source image resolution and drawable
    ///   resolution almost never match. The chain output is resampled
    ///   to the destination's dimensions.
    ///
    /// Both are done by a single MPS Lanczos resample. Lanczos is
    /// hardware-accelerated, costs <1 ms on modern Apple GPUs even at
    /// 4K, and produces bit-identical output at 1:1 sampling — so the
    /// matching-format / matching-size case does not need a separate
    /// blit shortcut. The single-path design is simpler to reason
    /// about and cheaper to test.
    ///
    /// Why this lives in the SDK: every real-time consumer needs this
    /// exact bridge, and `blit.copy` asserts across incompatible
    /// formats. Centralizing it here means consumers don't trip over
    /// the assertion discovering it themselves.
    ///
    /// - Parameters:
    ///   - commandBuffer: The command buffer to encode into. Caller
    ///     commits and presents.
    ///   - destination: Target texture. Must have `.shaderWrite` usage.
    /// - Throws: Texture resolution / PSO / encoder errors.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        writingTo destination: MTLTexture
    ) throws {
        let chainOutput = try encode(into: commandBuffer)
        try MPSDispatcher.lanczosResample(
            source: chainOutput,
            destination: destination,
            commandBuffer: commandBuffer
        )
    }

    // MARK: - Internal: encoding helper

    /// Encode the entire filter chain into a fresh command buffer and
    /// return both the buffer (uncommitted) and the final output texture.
    ///
    /// The returned buffer has its completion callback set up for async
    /// callers if needed; sync callers simply commit and wait.
    internal func encodeAll() throws -> (commandBuffer: MTLCommandBuffer, finalTexture: MTLTexture) {
        // 1. Resolve source
        let sourceTexture = try source.resolve(using: textureLoader)

        // 2. Optimize filter chain
        let optimizedSteps = optimizer.optimize(steps)

        // 3. Allocate command buffer from the pool (also enforces in-flight cap)
        let commandBuffer = try commandBufferPool.makeCommandBuffer(label: "DCR.Pipeline")

        // 4. Empty chain = return source directly (identity pipeline)
        guard !optimizedSteps.isEmpty else {
            return (commandBuffer, sourceTexture)
        }

        // 5. Execute steps, chaining outputs as inputs.
        var currentInput = sourceTexture
        var finalOutput: MTLTexture?
        var pendingEnqueue: [MTLTexture] = []

        for (index, step) in optimizedSteps.enumerated() {
            let isLastStep = (index == optimizedSteps.count - 1)
            let output = try executeStep(
                step,
                sourceTexture: currentInput,
                commandBuffer: commandBuffer
            )

            // Intermediate inputs can be returned to the pool once the CB
            // has finished executing on the GPU, but NOT earlier — see
            // `scheduleDeferredEnqueue` for the rationale.
            if currentInput !== sourceTexture, currentInput !== output {
                pendingEnqueue.append(currentInput)
            }

            currentInput = output
            if isLastStep {
                finalOutput = output
            }
        }

        scheduleDeferredEnqueue(
            textures: pendingEnqueue,
            pool: texturePool,
            commandBuffer: commandBuffer
        )

        return (commandBuffer, finalOutput ?? sourceTexture)
    }

    // MARK: - Internal: step dispatch

    /// Execute one step and return its output texture.
    internal func executeStep(
        _ step: AnyFilter,
        sourceTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        switch step {
        case .single(let filter):
            return try executeSinglePass(
                filter,
                sourceTexture: sourceTexture,
                commandBuffer: commandBuffer
            )

        case .multi(let filter):
            return try executeMultiPass(
                filter,
                sourceTexture: sourceTexture,
                commandBuffer: commandBuffer
            )
        }
    }

    private func executeSinglePass(
        _ filter: any FilterProtocol,
        sourceTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        // Give the filter a chance to preprocess (e.g. mask prep for
        // PortraitBlur). Most filters just return source unchanged.
        let effectiveSource = try filter.combinationBegin(
            commandBuffer: commandBuffer,
            source: sourceTexture
        )

        switch filter.modifier {
        case .compute(let kernel):
            // Allocate a destination texture matching the effective source.
            let destination = try texturePool.dequeue(spec: TexturePoolSpec(
                width: effectiveSource.width,
                height: effectiveSource.height,
                pixelFormat: intermediatePixelFormat,
                usage: [.shaderRead, .shaderWrite],
                storageMode: .private
            ))

            try ComputeDispatcher.dispatch(
                kernel: kernel,
                uniforms: filter.uniforms,
                additionalInputs: filter.additionalInputs,
                source: effectiveSource,
                destination: destination,
                commandBuffer: commandBuffer,
                psoCache: psoCache,
                uniformPool: uniformPool
            )

            try filter.combinationAfter(commandBuffer: commandBuffer)
            return destination

        case .render, .blit, .mps:
            // Single-pass render/blit/mps filters need custom dispatch entry
            // points that the generic Pipeline can't provide (vertex
            // buffers, blit-specific args, etc). Such filters must use the
            // pipeline-free dispatcher APIs directly.
            //
            // When we introduce StickerFilter etc in Phase 2, we'll either
            // extend AnyFilter with a `.render(any RenderFilterProtocol)`
            // case or let render filters adopt MultiPassFilter semantics.
            throw PipelineError.filter(.invalidPassGraph(
                filterName: String(describing: type(of: filter)),
                reason: "modifier \(filter.modifier) is not supported in generic Pipeline step dispatch yet"
            ))
        }
    }

    private func executeMultiPass(
        _ filter: any MultiPassFilter,
        sourceTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        // Feed the filter a TextureInfo whose pixelFormat reflects the
        // intermediate precision the filter's passes will actually run in,
        // not the source texture's on-disk/on-wire format. Same rationale
        // applies to the TextureInfo threaded through MultiPassExecutor
        // below — source.pixelFormat (e.g. bgra8Unorm for camera frames)
        // must not leak into intermediate allocations.
        let input = TextureInfo(
            width: sourceTexture.width,
            height: sourceTexture.height,
            pixelFormat: intermediatePixelFormat
        )
        let passes = filter.passes(input: input)
        return try MultiPassExecutor.execute(
            passes: passes,
            source: sourceTexture,
            intermediatePixelFormat: intermediatePixelFormat,
            commandBuffer: commandBuffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            texturePool: texturePool
        )
    }
}

// MARK: - Internal: CB-safe deferred enqueue

/// Schedule `textures` to be returned to `pool` only after
/// `commandBuffer` finishes executing on the GPU.
///
/// ## Why not enqueue immediately
///
/// A Metal command buffer encodes dispatches that read and write textures,
/// but the reads / writes happen *on the GPU* long after encoding returns
/// to the CPU. If we enqueue an intermediate texture as soon as a step's
/// encoding finishes, another pipeline running concurrently (different
/// queue, separate CB) could `dequeue` that same `MTLTexture` and start
/// writing to it — while the first CB is still reading from it on the GPU.
/// Metal's automatic hazard tracking protects reads / writes within a
/// single command buffer but not across command buffers; this is the
/// hazard the deferral closes.
///
/// Within the same command buffer the old eager-enqueue pattern was
/// actually safe (Metal's intra-CB hazard tracking inserts the needed
/// barriers), and the ping-pong pattern saved two texture allocations.
/// The deferred version trades those two saved allocations for cross-CB
/// correctness — the pool regains the intermediates as a batch at CB
/// completion, keeping them available for the *next* frame's dequeue.
internal func scheduleDeferredEnqueue(
    textures: [MTLTexture],
    pool: TexturePool,
    commandBuffer: MTLCommandBuffer
) {
    guard !textures.isEmpty else { return }
    // Box to satisfy `@Sendable` closure capture. `MTLTexture` is not
    // Sendable in Swift 6, but we only access it from the completion
    // callback (serial after GPU completion) and only hand it to
    // `pool.enqueue`, which is thread-safe via NSLock.
    let box = DeferredEnqueueBox(textures: textures, pool: pool)
    commandBuffer.addCompletedHandler { _ in
        box.flush()
    }
}

/// Captures a batch of textures + pool reference for handoff inside a
/// `@Sendable` completion handler. `@unchecked` because MTLTexture is not
/// Sendable and TexturePool's `enqueue` is internally locked — see
/// `scheduleDeferredEnqueue` doc for safety rationale.
private final class DeferredEnqueueBox: @unchecked Sendable {
    private let textures: [MTLTexture]
    private let pool: TexturePool

    init(textures: [MTLTexture], pool: TexturePool) {
        self.textures = textures
        self.pool = pool
    }

    func flush() {
        for texture in textures {
            pool.enqueue(texture)
        }
    }
}
