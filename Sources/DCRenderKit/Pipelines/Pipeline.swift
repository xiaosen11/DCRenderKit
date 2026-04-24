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

/// Strategies for the pipeline compiler's optimisation passes.
///
/// Introduced with Phase 5 of the pipeline-compiler refactor. Every
/// mode keeps the compiler in the dispatch path — lowering each
/// filter to an internal graph and running it on a runtime-compiled
/// uber kernel — but the optimisation passes between lowering and
/// codegen differ.
///
/// - ``full``: run every optimiser pass (dead-code elimination,
///   vertical fusion, common-subexpression elimination, kernel
///   inlining, tail sink). Chains of pixel-local filters collapse
///   into a single uber kernel; sibling multi-pass filters share
///   common downsample passes; adjacent pixel-local bodies ride
///   out of neighbour-read kernels. This is the mode the SDK
///   ships by default and the one the performance claims in the
///   README are written against.
///
/// - ``none``: skip the optimiser; every lowered node dispatches
///   through its own uber kernel. Useful as a debugging aid (the
///   output of a single filter is easier to inspect in isolation)
///   and as a fallback while diagnosing a suspected optimiser
///   regression. `.none` **does not** revert to pre-compiler
///   standalone kernels — all dispatch still flows through the
///   codegen path, only cross-filter fusion is disabled.
///
/// Cross-filter fusion lands in Phase 5 step 5.3. Until that step
/// lands, `.full` and `.none` are operationally equivalent for
/// every chain (single-filter lowering has nothing for the optimiser
/// to merge). The enum is introduced here so the public API is
/// stable before 5.3 flips the behaviour.
@available(iOS 18.0, *)
public enum PipelineOptimization: Sendable, Hashable {

    /// Run every optimiser pass. Default.
    case full

    /// Lower the chain but skip the optimiser. Each node dispatches
    /// through its own uber kernel, without cross-filter fusion.
    case none
}

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
/// A `Pipeline` instance is immutable once constructed. Its `source`,
/// `steps`, `optimizer`, and `intermediatePixelFormat` are `let`, and all
/// shared resources (PSO cache, uniform / texture / command-buffer pools)
/// are internally thread-safe. Multiple threads can therefore safely call
/// `encode(into:)` / `outputSync()` / `output()` on the same instance
/// concurrently, and multiple `Pipeline` instances can run concurrently
/// without coordination.
@available(iOS 18.0, *)
public final class Pipeline: @unchecked Sendable {

    // MARK: - Input

    /// The source of pixels to feed into the filter chain.
    public let source: PipelineInput

    /// The filter chain, in execution order. Fixed at construction; build
    /// a new `Pipeline` to change it.
    public let steps: [AnyFilter]

    // MARK: - Configuration

    /// Optimization strategy applied to `steps` before execution.
    /// Defaults to the standard optimizer (passthrough in Phase 1).
    public let optimizer: FilterGraphOptimizer

    /// Compiler optimisation strategy for the pipeline graph. See
    /// ``PipelineOptimization``. Defaults to ``PipelineOptimization/full``.
    ///
    /// Introduced with the Phase-5 pipeline-compiler refactor. Until
    /// cross-filter fusion lands in step 5.3, `.full` and `.none`
    /// behave identically — every chain compiles to one uber kernel
    /// per filter.
    public let optimization: PipelineOptimization

    /// Pixel format of intermediate textures between filters.
    ///
    /// Default is `.rgba16Float` which is the right choice for commercial-
    /// grade precision: eliminates the per-filter 8-bit quantization that
    /// accumulates visible banding in long chains. Set this to
    /// `.bgra8Unorm` only if memory pressure demands it and you've
    /// verified the resulting banding is acceptable for your content.
    public let intermediatePixelFormat: MTLPixelFormat

    /// Color space the intermediate textures carry.
    ///
    /// Stored for consumer introspection (e.g. the demo reads
    /// `pipeline.colorSpace.recommendedDrawablePixelFormat` to pick its
    /// MTKView format). Filters read ``DCRenderKit.defaultColorSpace``
    /// directly at uniform-build time; this per-instance value is *not*
    /// currently threaded through the filter dispatch path. A future
    /// refactor may promote per-Pipeline override; until then, expect
    /// `pipeline.colorSpace == DCRenderKit.defaultColorSpace` to hold
    /// for the SDK's own filters.
    public let colorSpace: DCRColorSpace

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
        steps: [AnyFilter] = [],
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace,
        optimization: PipelineOptimization = .full
    ) {
        self.source = input
        self.steps = steps
        self.optimizer = FilterGraphOptimizer()
        self.optimization = optimization
        self.intermediatePixelFormat = .rgba16Float
        self.colorSpace = colorSpace
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
        optimization: PipelineOptimization = .full,
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace,
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
        self.optimization = optimization
        self.intermediatePixelFormat = intermediatePixelFormat
        self.colorSpace = colorSpace
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

        return try executeChain(
            steps: optimizedSteps,
            source: sourceTexture,
            commandBuffer: commandBuffer
        )
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

        // 2. Optimize filter chain (legacy FilterGraphOptimizer — currently
        //    passthrough; the compiler path in `executeChain` runs the
        //    Phase-2 optimiser on its own lowered IR).
        let optimizedSteps = optimizer.optimize(steps)

        // 3. Allocate command buffer from the pool (also enforces in-flight cap)
        let commandBuffer = try commandBufferPool.makeCommandBuffer(label: "DCR.Pipeline")

        // 4. Empty chain = return source directly (identity pipeline)
        guard !optimizedSteps.isEmpty else {
            return (commandBuffer, sourceTexture)
        }

        let finalTexture = try executeChain(
            steps: optimizedSteps,
            source: sourceTexture,
            commandBuffer: commandBuffer
        )
        return (commandBuffer, finalTexture)
    }

    // MARK: - Internal: chain execution (compiler path + per-step fallback)

    /// Execute `steps` in the given command buffer, preferring the
    /// graph-level pipeline-compiler path (Phase 5 step 5.3) when the
    /// lowered chain contains only `ComputeBackend`-dispatchable nodes.
    /// Falls back to the per-step loop for chains with multi-pass
    /// filters (whose passes lower to `.nativeCompute` nodes the
    /// backend does not generate code for) or with render / blit / MPS
    /// modifiers that `Lowering` cannot translate.
    private func executeChain(
        steps: [AnyFilter],
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        if let finalTexture = try tryCompilerPath(
            steps: steps,
            source: source,
            commandBuffer: commandBuffer
        ) {
            return finalTexture
        }
        return try executePerStepFallback(
            steps: steps,
            source: source,
            commandBuffer: commandBuffer
        )
    }

    /// Per-step dispatch. The original Phase-1 implementation of the
    /// chain loop; still used for chains the compiler path can't cover
    /// today (multi-pass filters, non-compute single-pass modifiers,
    /// filters without a `fusionBody`).
    private func executePerStepFallback(
        steps: [AnyFilter],
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        var currentInput = source
        var finalOutput: MTLTexture?
        var pendingEnqueue: [MTLTexture] = []

        for (index, step) in steps.enumerated() {
            let isLastStep = (index == steps.count - 1)
            let output = try executeStep(
                step,
                sourceTexture: currentInput,
                commandBuffer: commandBuffer
            )

            // Intermediate inputs can be returned to the pool once the CB
            // has finished executing on the GPU, but NOT earlier — see
            // `scheduleDeferredEnqueue` for the rationale.
            if currentInput !== source, currentInput !== output {
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

        return finalOutput ?? source
    }

    /// Attempt to dispatch the entire chain through the pipeline
    /// compiler: `Lowering` → `Optimizer` (skipped in `.none`) →
    /// `LifetimeAwareTextureAllocator` → per-node dispatch (either
    /// `ComputeBackend` for fusion-eligible node kinds or
    /// `ComputeDispatcher` for opaque `.nativeCompute` nodes).
    /// Returns `nil` only when `Lowering` itself cannot produce a
    /// graph — the caller then falls back to the per-step loop for
    /// chains containing render / blit / MPS single-pass modifiers.
    ///
    /// Phase 6 expanded this path to cover mixed chains. Previously
    /// the eligibility check rejected graphs containing any
    /// `.nativeCompute` node (emitted for every pass of a multi-pass
    /// filter), which dropped the entire chain to the per-step
    /// loop — forfeiting both the allocator's aliasing and the
    /// optimiser's cluster dispatch. The current implementation
    /// routes `.nativeCompute` through the legacy `ComputeDispatcher`
    /// path from inside the same graph traversal, so aliasing
    /// applies across the full chain and `VerticalFusion` clusters
    /// fire even with multi-pass filters in the mix.
    ///
    /// Cross-filter fusion (pixel-local cluster) lands through
    /// `VerticalFusion` inside `Optimizer.optimize`, so a 3-filter
    /// tone chain (`[Exposure, Contrast, Saturation]`) collapses to
    /// a single cluster node — and therefore a single uber-kernel
    /// dispatch — under `.full`. A 16-filter mixed chain collapses
    /// into pixel-local clusters around each multi-pass filter plus
    /// one opaque `.nativeCompute` node per multi-pass inner pass,
    /// with intermediate textures aliased by lifetime.
    private func tryCompilerPath(
        steps: [AnyFilter],
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture? {
        let sourceInfo = TextureInfo(
            width: source.width,
            height: source.height,
            pixelFormat: source.pixelFormat
        )
        guard let lowered = Lowering.lower(steps, source: sourceInfo) else {
            return nil
        }

        let graph: PipelineGraph
        switch optimization {
        case .full:
            graph = Optimizer.optimize(lowered)
        case .none:
            graph = lowered
        }

        let destInfo = TextureInfo(
            width: source.width,
            height: source.height,
            pixelFormat: intermediatePixelFormat
        )
        let allocator = LifetimeAwareTextureAllocator(pool: texturePool)
        let allocation = try allocator.allocate(
            graph: graph,
            sourceInfo: destInfo
        )

        let globalAdditional = collectGlobalAdditionalInputs(from: steps)

        for node in graph.nodes {
            try dispatchCompilerNode(
                node: node,
                source: source,
                allocation: allocation,
                globalAdditional: globalAdditional,
                commandBuffer: commandBuffer
            )
        }

        allocator.scheduleRelease(allocation, commandBuffer: commandBuffer)

        guard let finalTexture = allocation.mapping[graph.finalID] else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: "Pipeline",
                reason: "allocator produced no texture for final node \(graph.finalID)"
            ))
        }
        return finalTexture
    }

    /// Dispatch a single compiler-path node. Fusion-eligible kinds
    /// (`.pixelLocal` / `.neighborRead` / `.fusedPixelLocalCluster`)
    /// go through `ComputeBackend` which compiles and caches a
    /// runtime-generated uber kernel. `.nativeCompute` (a
    /// multi-pass filter's inner pass) goes through
    /// `ComputeDispatcher` with the node's carried kernel name — the
    /// same dispatch the pre-Phase-5 `MultiPassExecutor` used, only
    /// now driven from the graph loop so the allocator controls the
    /// destination texture.
    private func dispatchCompilerNode(
        node: Node,
        source: MTLTexture,
        allocation: LifetimeAwareTextureAllocator.Allocation,
        globalAdditional: [MTLTexture],
        commandBuffer: MTLCommandBuffer
    ) throws {
        let primaryRef = node.inputs.first ?? .source
        let primaryInput = try resolveCompilerInput(
            ref: primaryRef,
            source: source,
            allocation: allocation,
            globalAdditional: globalAdditional,
            context: node.debugLabel
        )

        guard let destination = allocation.mapping[node.id] else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: node.debugLabel,
                reason: "allocator has no destination texture for node \(node.id)"
            ))
        }

        switch node.kind {
        case .pixelLocal, .neighborRead, .fusedPixelLocalCluster:
            try ComputeBackend.execute(
                node: node,
                source: primaryInput,
                destination: destination,
                additionalInputs: globalAdditional,
                commandBuffer: commandBuffer,
                uniformPool: uniformPool
            )

        case let .nativeCompute(kernelName, uniforms, additionalRefs):
            // Resolve every NodeRef this opaque kernel reads beyond
            // its primary input — these translate to the `additional
            // Inputs` parameter `ComputeDispatcher.dispatch` binds
            // at texture slots 2+ in declaration order.
            var nodeAdditional: [MTLTexture] = []
            nodeAdditional.reserveCapacity(additionalRefs.count)
            for ref in additionalRefs {
                nodeAdditional.append(try resolveCompilerInput(
                    ref: ref,
                    source: source,
                    allocation: allocation,
                    globalAdditional: globalAdditional,
                    context: node.debugLabel
                ))
            }
            try ComputeDispatcher.dispatch(
                kernel: kernelName,
                uniforms: uniforms,
                additionalInputs: nodeAdditional,
                source: primaryInput,
                destination: destination,
                commandBuffer: commandBuffer,
                psoCache: psoCache,
                uniformPool: uniformPool
            )

        case .downsample, .upsample, .reduce, .blend:
            // Reserved optimiser kinds not currently emitted by
            // `Lowering`. Reaching here means the graph was hand-
            // constructed (test fixture) or a future optimiser added
            // a pass whose codegen isn't wired yet — surface the
            // mismatch explicitly rather than silently dropping the
            // dispatch.
            throw PipelineError.filter(.invalidPassGraph(
                filterName: node.debugLabel,
                reason: "compiler-path dispatch does not handle node kind \(node.kind)"
            ))
        }
    }

    /// Translate a `NodeRef` carried inside a compiler-path node into
    /// a concrete `MTLTexture`.
    private func resolveCompilerInput(
        ref: NodeRef,
        source: MTLTexture,
        allocation: LifetimeAwareTextureAllocator.Allocation,
        globalAdditional: [MTLTexture],
        context: String
    ) throws -> MTLTexture {
        switch ref {
        case .source:
            return source
        case .node(let id):
            guard let tex = allocation.mapping[id] else {
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: context,
                    reason: "allocator has no texture for node \(id)"
                ))
            }
            return tex
        case .additional(let i):
            guard i >= 0, i < globalAdditional.count else {
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: context,
                    reason: ".additional(\(i)) out of range of \(globalAdditional.count) graph-global inputs"
                ))
            }
            return globalAdditional[i]
        }
    }

    /// Flatten every step's `additionalInputs` array into a single
    /// graph-global list matching the indices `Lowering` assigns to
    /// `.additional(_)` references.
    private func collectGlobalAdditionalInputs(
        from steps: [AnyFilter]
    ) -> [MTLTexture] {
        var result: [MTLTexture] = []
        for step in steps {
            switch step {
            case .single(let f): result.append(contentsOf: f.additionalInputs)
            case .multi(let f):  result.append(contentsOf: f.additionalInputs)
            }
        }
        return result
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

            // Phase-5 step 5.1: filters that expose a `fusionBody`
            // descriptor dispatch through the compiler-driven
            // ComputeBackend (runtime uber-kernel codegen). Filters
            // without a descriptor (the `.unsupported` default — legacy
            // third-party filters, etc.) fall through to the standalone
            // kernel that `.compute(kernel:)` names. Built-in SDK
            // filters all ship descriptors, so production now runs the
            // codegen path by default; the parity gate in
            // `LegacyParityTests` guarantees bit-close equivalence.
            if filter.fusionBody.body != nil {
                try dispatchThroughComputeBackend(
                    filter: filter,
                    source: effectiveSource,
                    destination: destination,
                    commandBuffer: commandBuffer
                )
            } else {
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
            }

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

    /// Lower a single-pass filter to a one-node `PipelineGraph`, then
    /// execute that node through `ComputeBackend`. Phase-5 step 5.1
    /// introduced this path for filters that expose a `fusionBody`
    /// descriptor; the codegen uber kernel replaces the filter's
    /// production standalone kernel at dispatch time.
    ///
    /// This single-filter path does not yet run the optimiser — a one-
    /// node graph has no cross-filter fusion opportunity. Multi-filter
    /// fusion lands when Phase 5 rewrites `encode(into:)` to lower the
    /// whole chain through `Lowering` + `Optimizer` at once (5.3).
    private func dispatchThroughComputeBackend(
        filter: any FilterProtocol,
        source: MTLTexture,
        destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let sourceInfo = TextureInfo(
            width: source.width,
            height: source.height,
            pixelFormat: source.pixelFormat
        )
        guard let graph = Lowering.lower([.single(filter)], source: sourceInfo),
              let node = graph.nodes.first else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: String(describing: type(of: filter)),
                reason: "lowering yielded no node for a single-pass filter with fusionBody"
            ))
        }

        try ComputeBackend.execute(
            node: node,
            source: source,
            destination: destination,
            additionalInputs: filter.additionalInputs,
            commandBuffer: commandBuffer,
            uniformPool: uniformPool
        )
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
            additionalInputs: filter.additionalInputs,
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
