//
//  Pipeline.swift
//  DCRenderKit
//
//  Top-level user-facing API. Composes `TextureLoader`, the pipeline
//  compiler (`Lowering` → `Optimizer` → `LifetimeAwareTextureAllocator`),
//  and the dispatchers (`ComputeBackend`, `RenderBackend`,
//  `ComputeDispatcher`) into a single `encode(into:)` call that
//  business code interacts with.
//

import Foundation
import Metal

/// Strategies for the pipeline compiler's optimisation passes.
///
/// Every mode keeps the compiler in the dispatch path — lowering each
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
///   and while diagnosing a suspected optimiser regression. `.none`
///   **does not** revert to pre-compiler standalone kernels — all
///   dispatch still flows through the codegen path, only cross-
///   filter fusion is disabled.
@available(iOS 18.0, *)
public enum PipelineOptimization: Sendable, Hashable {

    /// Run every optimiser pass. Default.
    case full

    /// Lower the chain but skip the optimiser. Each node dispatches
    /// through its own uber kernel, without cross-filter fusion.
    case none
}

/// Long-lived renderer for filter-chain execution.
///
/// `Pipeline` is the SDK's compiler context: it owns the resource
/// pools, PSO caches, and the per-renderer compiled-chain cache.
/// Each call to ``encode(into:source:steps:writingTo:)`` (or its
/// siblings) supplies the **source texture** and **filter chain**
/// for that specific job. Holding one `Pipeline` across many
/// encode calls is the supported pattern — repeated encodes with
/// the same chain topology hit ``CompiledChainCache`` and skip
/// every optimiser pass.
///
/// ## Minimal usage
///
/// ```swift
/// // Long-lived (e.g. owned by a SwiftUI Coordinator).
/// let pipeline = Pipeline()
///
/// // Hot-path encode (preview, video, MTKView.draw):
/// try pipeline.encode(
///     into: commandBuffer,
///     source: cameraTexture,
///     steps: chain,
///     writingTo: drawable.texture
/// )
///
/// // One-shot batch (export, snapshot):
/// let output = try pipeline.processSync(
///     input: .uiImage(myImage),
///     steps: chain
/// )
/// ```
///
/// ## Execution model
///
/// 1. The supplied source resolves to an `MTLTexture` via
///    `TextureLoader` (zero-cost when already an `MTLTexture`).
/// 2. The pipeline compiler runs:
///    - `Lowering` translates the filter chain into a `PipelineGraph`.
///    - ``CompiledChainCache`` lookup keyed on the lowered-graph
///      fingerprint + source spec + optimisation skips the next
///      three passes on hit.
///    - `Optimizer` rewrites the graph (DCE, vertical fusion, CSE,
///      kernel inlining, tail sink) — skipped under
///      ``PipelineOptimization/none``.
///    - `LifetimeAwareTextureAllocator` assigns a pooled texture to
///      each node with interval-graph aliasing; chain-internal
///      cluster outputs alias to the chain tail's bucket.
/// 3. The pipeline walks the graph in declaration order and
///    dispatches each node through the appropriate backend
///    (`ComputeBackend`, `RenderBackend`, or `ComputeDispatcher`).
///    Adjacent pixel-local clusters batch into a single chained
///    render pass with programmable blending.
/// 4. `commandBuffer` is committed by the caller (for `encode(...)`)
///    or by the pipeline (for `process` / `processSync`).
///
/// ## Thread safety
///
/// A `Pipeline` instance carries only immutable configuration plus
/// internally-synchronised caches (`CompiledChainCache` is
/// `NSLock`-guarded; `TexturePool` / `PipelineStateCache` /
/// `UniformBufferPool` are all thread-safe). Multiple threads can
/// safely call `encode` / `process` / `processSync` on the same
/// instance concurrently. Multiple `Pipeline` instances run
/// independently with no coordination.
@available(iOS 18.0, *)
public final class Pipeline: @unchecked Sendable {

    // MARK: - Configuration

    /// Compiler optimisation strategy for the pipeline graph. See
    /// ``PipelineOptimization``. Defaults to ``PipelineOptimization/full``.
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
    internal let shaderLibrary: ShaderLibrary
    internal let uberKernelCache: UberKernelCache
    internal let uberRenderCache: UberRenderPipelineCache

    /// Per-instance memoisation of `Optimizer` + chain-internal
    /// alias + `TextureAliasingPlanner` output. Hits when the
    /// chain topology and source dimensions don't change between
    /// frames — the common preview-loop case. See
    /// ``CompiledChainCache``.
    internal let compiledChainCache = CompiledChainCache()

    // MARK: - Init

    /// Create a pipeline bound to the default (shared) resource instances.
    public init(
        optimization: PipelineOptimization = .full,
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) {
        self.optimization = optimization
        self.intermediatePixelFormat = intermediatePixelFormat
        self.colorSpace = colorSpace
        self.device = .shared
        self.textureLoader = .shared
        self.psoCache = .shared
        self.uniformPool = .shared
        self.samplerCache = .shared
        self.texturePool = .shared
        self.commandBufferPool = .shared
        self.shaderLibrary = .shared
        self.uberKernelCache = .shared
        self.uberRenderCache = .shared
    }

    /// Create a pipeline with fully-specified dependencies. Primarily for
    /// tests that need isolated pools, or for production multi-Pipeline
    /// scenarios where each Pipeline needs its own resource budget.
    ///
    /// For the typical multi-Pipeline shape — independent
    /// `texturePool` / `commandBufferPool` / `uniformPool` but shared
    /// PSO caches and `ShaderLibrary` — see ``Pipeline/makeIsolated(...)``
    /// which is a convenience factory over this init.
    public init(
        optimization: PipelineOptimization = .full,
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace,
        device: Device,
        textureLoader: TextureLoader,
        psoCache: PipelineStateCache,
        uniformPool: UniformBufferPool,
        samplerCache: SamplerCache,
        texturePool: TexturePool,
        commandBufferPool: CommandBufferPool,
        shaderLibrary: ShaderLibrary = .shared,
        uberKernelCache: UberKernelCache = .shared,
        uberRenderCache: UberRenderPipelineCache = .shared
    ) {
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
        self.shaderLibrary = shaderLibrary
        self.uberKernelCache = uberKernelCache
        self.uberRenderCache = uberRenderCache
    }

    // MARK: - Hot-path encode (caller-managed command buffer)

    /// Encode `steps` into `commandBuffer`, sampling from `source`,
    /// and write the final result into `destination`.
    ///
    /// **The hot-path API.** Holding one long-lived `Pipeline` and
    /// calling this per frame is the supported pattern for camera
    /// preview / video / MTKView integration. The `CompiledChainCache`
    /// hits whenever the chain topology and source dimensions match
    /// the previous call — slider drags (uniform-only changes) and
    /// fresh per-frame `MTLTexture` references both stay on the cache
    /// hot path.
    ///
    /// Empty `steps` ⇒ MPS Lanczos blit from `source` to `destination`,
    /// handling format / size mismatch in one pass.
    ///
    /// - Parameters:
    ///   - commandBuffer: Target command buffer; caller commits and
    ///     presents.
    ///   - source: Already-resolved source texture for this frame.
    ///   - steps: Filter chain for this frame. Empty = identity.
    ///   - destination: Final output target (typically
    ///     `CAMetalDrawable.texture`). Must have `.shaderWrite`.
    /// - Throws: Texture resolution / PSO / encoder errors.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        steps: [AnyFilter],
        writingTo destination: MTLTexture
    ) throws {
        if steps.isEmpty {
            try MPSDispatcher.lanczosResample(
                source: source,
                destination: destination,
                commandBuffer: commandBuffer
            )
            return
        }
        let chainOutput = try executeChain(
            steps: steps,
            source: source,
            commandBuffer: commandBuffer
        )
        try MPSDispatcher.lanczosResample(
            source: chainOutput,
            destination: destination,
            commandBuffer: commandBuffer
        )
    }

    /// Encode `steps` into `commandBuffer`, sampling from `source`,
    /// and return the final output texture (in the pipeline's
    /// `intermediatePixelFormat`).
    ///
    /// Use this when the caller wants to receive the chain output
    /// for further processing (e.g. additional dispatch into a
    /// custom render target, snapshot capture). For drawable
    /// presentation use the `writingTo:` overload.
    ///
    /// Empty `steps` returns `source` unchanged — no encoding work.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        steps: [AnyFilter]
    ) throws -> MTLTexture {
        guard !steps.isEmpty else { return source }
        return try executeChain(
            steps: steps,
            source: source,
            commandBuffer: commandBuffer
        )
    }

    // MARK: - One-shot batch (pipeline-managed command buffer)

    /// Execute `steps` against `input` and block until the GPU finishes.
    /// Convenience for export / snapshot / test use.
    ///
    /// Prefer ``process(input:steps:)`` (async) for production code.
    public func processSync(
        input: PipelineInput,
        steps: [AnyFilter]
    ) throws -> MTLTexture {
        let (commandBuffer, finalTexture) = try encodeAll(input: input, steps: steps)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error {
            throw PipelineError.device(.gpuExecutionFailed(underlying: err))
        }
        return finalTexture
    }

    // MARK: - Internal: encoding helper

    /// Resolve `input`, allocate a CB from the pool, encode the chain.
    /// Used by both `processSync` and `process` (async).
    internal func encodeAll(
        input: PipelineInput,
        steps: [AnyFilter]
    ) throws -> (commandBuffer: MTLCommandBuffer, finalTexture: MTLTexture) {
        let sourceTexture = try input.resolve(using: textureLoader)
        let commandBuffer = try commandBufferPool.makeCommandBuffer(label: "DCR.Pipeline")

        guard !steps.isEmpty else {
            return (commandBuffer, sourceTexture)
        }

        let finalTexture = try executeChain(
            steps: steps,
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
    /// chain loop; retained as a safety net for chains the compiler
    /// path can't cover (non-compute single-pass modifiers —
    /// render / blit / MPS — which `Lowering` rejects). Post-Phase-6
    /// built-in filter chains don't reach it.
    private func executePerStepFallback(
        steps: [AnyFilter],
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        if DCRLogging.diagnosticPipelineLogging {
            DCRLogging.logger.debug(
                "per-step fallback engaged",
                category: "PipelineCompiler",
                attributes: [
                    "chainLength": "\(steps.count)",
                    "note": "Lowering rejected the chain — likely render/blit/mps modifier",
                ]
            )
        }
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
            if DCRLogging.diagnosticPipelineLogging {
                DCRLogging.logger.debug(
                    "compiler path rejected: Lowering returned nil",
                    category: "PipelineCompiler",
                    attributes: [
                        "chainLength": "\(steps.count)",
                        "reason": "non-compute single-pass modifier or malformed multi-pass",
                    ]
                )
            }
            return nil
        }

        let destInfo = TextureInfo(
            width: source.width,
            height: source.height,
            pixelFormat: intermediatePixelFormat
        )

        // Cache lookup keyed by (lowered fingerprint, source spec,
        // optimization, intermediate format). Hits skip Optimizer
        // + chain-internal walk + planner — the entire CPU portion
        // of compilation. Misses fall through and cache the result
        // for subsequent frames.
        let loweredFingerprint = CompiledChainCache.fingerprint(of: lowered)
        let cacheHit = compiledChainCache.lookup(
            loweredFingerprint: loweredFingerprint,
            sourceInfo: sourceInfo,
            intermediatePixelFormat: intermediatePixelFormat,
            optimization: optimization
        )

        let graph: PipelineGraph
        let chainInternalAlias: [NodeID: NodeID]
        let plan: TextureAliasingPlan
        if let cached = cacheHit {
            graph = cached.optimizedGraph
            chainInternalAlias = cached.chainInternalAlias
            plan = cached.plan
        } else {
            switch optimization {
            case .full:
                graph = Optimizer.optimize(lowered)
            case .none:
                graph = lowered
            }
            chainInternalAlias = Self.computeChainInternalAlias(graph: graph)
            plan = TextureAliasingPlanner.plan(
                graph: graph,
                sourceInfo: destInfo,
                chainInternalAlias: chainInternalAlias
            )
            compiledChainCache.store(CompiledChainCache.Entry(
                loweredFingerprint: loweredFingerprint,
                sourceWidth: sourceInfo.width,
                sourceHeight: sourceInfo.height,
                sourcePixelFormat: sourceInfo.pixelFormat,
                intermediatePixelFormat: intermediatePixelFormat,
                optimization: optimization,
                optimizedGraph: graph,
                chainInternalAlias: chainInternalAlias,
                plan: plan
            ))
        }

        if DCRLogging.diagnosticPipelineLogging {
            let stats = Self.graphStats(lowered: lowered, optimized: graph)
            DCRLogging.logger.debug(
                "compiler path taken",
                category: "PipelineCompiler",
                attributes: [
                    "chainLength": "\(steps.count)",
                    "optimization": (optimization == .full) ? "full" : "none",
                    "loweredNodes": "\(lowered.nodes.count)",
                    "optimizedNodes": "\(graph.nodes.count)",
                    "clusters": "\(stats.clusters)",
                    "inlinedBodies": "\(stats.inlinedBodies)",
                    "tailSunkBodies": "\(stats.tailSunkBodies)",
                    "nativeCompute": "\(stats.nativeCompute)",
                    "cacheHit": cacheHit != nil ? "1" : "0",
                ]
            )
        }

        let allocator = LifetimeAwareTextureAllocator(pool: texturePool)
        let allocation = try allocator.materialize(
            plan: plan,
            finalID: graph.finalID
        )

        if DCRLogging.diagnosticPipelineLogging {
            let bucketCount = allocation.plan.uniqueBucketCount
            let totalBytes = allocation.plan.bucketSpec.values
                .reduce(0) { $0 + Self.byteEstimate($1) }
            let ratioStr: String
            if graph.nodes.count > 0 {
                let ratio = Double(graph.nodes.count) / Double(max(bucketCount, 1))
                ratioStr = String(format: "%.2f", ratio)
            } else {
                ratioStr = "∞"
            }
            DCRLogging.logger.debug(
                "allocator plan",
                category: "PipelineMem",
                attributes: [
                    "nodes": "\(graph.nodes.count)",
                    "buckets": "\(bucketCount)",
                    "compressionRatio": ratioStr,
                    "peakBytes": "\(totalBytes)",
                    "peakMB": String(format: "%.1f", Double(totalBytes) / (1024 * 1024)),
                ]
            )
        }

        let globalAdditional = collectGlobalAdditionalInputs(from: steps)

        // Phase 8: walk the graph in declaration order, batching
        // contiguous runs of `.fusedPixelLocalCluster` nodes (where
        // each cluster is the sole consumer of the previous) into a
        // single chained render pass. Single-element batches and
        // every other node kind fall through to per-node dispatch.
        var i = 0
        while i < graph.nodes.count {
            let chain = Self.collectFragmentChain(
                graph: graph,
                startIndex: i
            )
            if chain.count >= 2 {
                try dispatchFragmentChain(
                    nodes: chain,
                    source: source,
                    allocation: allocation,
                    globalAdditional: globalAdditional,
                    commandBuffer: commandBuffer
                )
                i += chain.count
            } else {
                try dispatchCompilerNode(
                    node: graph.nodes[i],
                    source: source,
                    allocation: allocation,
                    globalAdditional: globalAdditional,
                    commandBuffer: commandBuffer
                )
                i += 1
            }
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

    /// Structural counts derived from a lowered / optimised graph
    /// used by the diagnostic `PipelineCompiler` log line. Computing
    /// them is O(N); the enclosing call site only runs when
    /// ``DCRLogging/diagnosticPipelineLogging`` is true.
    private struct GraphStats {
        let clusters: Int
        let inlinedBodies: Int
        let tailSunkBodies: Int
        let nativeCompute: Int
    }

    private static func graphStats(
        lowered: PipelineGraph,
        optimized: PipelineGraph
    ) -> GraphStats {
        var clusters = 0
        var inlined = 0
        var tailSunk = 0
        var nativeCompute = 0
        for node in optimized.nodes {
            if case .fusedPixelLocalCluster = node.kind {
                clusters += 1
            }
            if case .nativeCompute = node.kind {
                nativeCompute += 1
            }
            if node.inlinedBodyBeforeSample != nil {
                inlined += 1
            }
            if node.tailSinkedBody != nil {
                tailSunk += 1
            }
        }
        return GraphStats(
            clusters: clusters,
            inlinedBodies: inlined,
            tailSunkBodies: tailSunk,
            nativeCompute: nativeCompute
        )
    }

    /// Approximate byte estimate for a `TextureInfo` — mirrors the
    /// `TexturePool` table closely enough for the diagnostic log to
    /// be comparable against pool readings.
    private static func byteEstimate(_ info: TextureInfo) -> Int {
        let bytesPerPixel: Int
        switch info.pixelFormat {
        case .rgba16Float:                         bytesPerPixel = 8
        case .rgba32Float:                         bytesPerPixel = 16
        case .bgra8Unorm, .rgba8Unorm,
             .bgra8Unorm_srgb, .rgba8Unorm_srgb:   bytesPerPixel = 4
        default:                                   bytesPerPixel = 8
        }
        return info.width * info.height * bytesPerPixel
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
                uberCache: uberKernelCache,
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
                uniformPool: uniformPool,
                library: shaderLibrary
            )

        case let .downsample(_, kind):
            // Structural reduction — `Lowering` emits
            // `.downsample(factor: 4, kind: .guidedLuma)` for the
            // shared 4× luma downsample that HighlightShadow and
            // Clarity both need. CSE dedups the pair into one
            // node before we get here, so the dispatch runs the
            // backing kernel exactly once even when both filters
            // are in the chain.
            switch kind {
            case .guidedLuma:
                try ComputeDispatcher.dispatch(
                    kernel: "DCRGuidedDownsampleLuma",
                    uniforms: .empty,
                    additionalInputs: [],
                    source: primaryInput,
                    destination: destination,
                    commandBuffer: commandBuffer,
                    psoCache: psoCache,
                    uniformPool: uniformPool,
                    library: shaderLibrary
                )
            case .boxAvg, .mpsMean:
                // The IR carries these for future emitters
                // (pyramid bases, MPS reductions) but Lowering
                // does not produce them today. Failing here
                // catches the unrecognised case explicitly when
                // a new emitter forgets to wire its kernel.
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: node.debugLabel,
                    reason: "downsample kind \(kind) has no dispatch wired"
                ))
            }

        case .upsample, .reduce, .blend:
            // Reserved optimiser kinds the IR can produce but the
            // dispatch path has no consumer for yet. Reaching here
            // means a future optimiser pass started emitting one
            // without wiring its dispatch — surface the mismatch
            // rather than silently dropping it.
            throw PipelineError.filter(.invalidPassGraph(
                filterName: node.debugLabel,
                reason: "compiler-path dispatch does not handle node kind \(node.kind)"
            ))
        }
    }

    /// Phase 8: scan forward from `startIndex` collecting a
    /// contiguous run of `.fusedPixelLocalCluster` nodes where each
    /// cluster's only consumer is the next cluster (no fan-out, no
    /// foreign reads of the intermediate output). The first
    /// out-of-shape node ends the run.
    ///
    /// Constraints for chaining inside one render pass:
    ///
    /// 1. Every node is `.fusedPixelLocalCluster`.
    /// 2. Each non-final cluster has exactly one consumer in the
    ///    whole graph, and that consumer is the next cluster — this
    ///    means the cluster's output is never read elsewhere, so
    ///    there's no need to materialise it as a real texture.
    /// 3. The next cluster's primary input is `.node(prev.id)`.
    ///
    /// Returns at most one node when no chain is available — the
    /// caller treats that as "single-node, dispatch normally".
    private static func collectFragmentChain(
        graph: PipelineGraph,
        startIndex: Int
    ) -> [Node] {
        let head = graph.nodes[startIndex]
        guard isChainInitEligible(head) else {
            return [head]
        }
        let consumers = consumerCounts(graph: graph)
        var chain: [Node] = [head]
        var lastID = head.id
        var cursor = startIndex + 1
        while cursor < graph.nodes.count {
            let candidate = graph.nodes[cursor]
            guard isChainContinuationEligible(candidate) else { break }
            guard let prevNode = chain.last else { break }
            if prevNode.isFinal { break }
            if (consumers[lastID] ?? 0) != 1 { break }
            guard candidate.inputs == [.node(lastID)] else { break }
            chain.append(candidate)
            lastID = candidate.id
            cursor += 1
        }
        return chain
    }

    /// `true` if `node` can serve as the FIRST (init) draw of a
    /// fragment render chain. Every `.pixelLocal` shape and every
    /// `.fusedPixelLocalCluster` qualifies; `.neighborRead` also
    /// qualifies as init-only because its body samples the source
    /// texture directly. Multi-pass `.nativeCompute` and
    /// downsample / upsample / blend nodes never join a fragment
    /// pass — they need a separate compute encoder.
    private static func isChainInitEligible(_ node: Node) -> Bool {
        switch node.kind {
        case .fusedPixelLocalCluster:
            return true
        case let .pixelLocal(body, _, _, _):
            return body.signatureShape != .pixelLocalWithGid
        case let .neighborRead(body, _, _, _):
            return body.signatureShape == .neighborReadWithSource
        default:
            return false
        }
    }

    /// `true` if `node` can occupy a non-first position in a
    /// fragment render chain. Programmable-blending input gives
    /// only the current pixel, which excludes any body that needs
    /// to sample a source neighbourhood — i.e. `.neighborRead`
    /// drops out here and a chain ends at the first such node.
    private static func isChainContinuationEligible(_ node: Node) -> Bool {
        switch node.kind {
        case .fusedPixelLocalCluster:
            return true
        case let .pixelLocal(body, _, _, _):
            return body.signatureShape != .pixelLocalWithGid
                && body.signatureShape != .neighborReadWithSource
        case .neighborRead:
            return false
        default:
            return false
        }
    }

    /// Tally how many other nodes reference each node's output.
    /// Mirrors the helper `VerticalFusion` / `KernelInlining` use,
    /// duplicated here to keep `Pipeline` self-contained.
    private static func consumerCounts(graph: PipelineGraph) -> [NodeID: Int] {
        var counts: [NodeID: Int] = [:]
        for node in graph.nodes {
            for ref in node.dependencyRefs {
                if case .node(let id) = ref {
                    counts[id, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Walk the graph the same way `executeChain`'s dispatch loop
    /// does and return `[chainInternalNodeID: chainTailID]` for
    /// every multi-node fragment chain found. Used by
    /// `tryCompilerPath` to tell the allocator which clusters
    /// don't need physical destinations.
    private static func computeChainInternalAlias(
        graph: PipelineGraph
    ) -> [NodeID: NodeID] {
        var alias: [NodeID: NodeID] = [:]
        var i = 0
        while i < graph.nodes.count {
            let chain = collectFragmentChain(graph: graph, startIndex: i)
            if chain.count >= 2 {
                let tailID = chain.last!.id
                for cluster in chain.dropLast() {
                    alias[cluster.id] = tailID
                }
                i += chain.count
            } else {
                i += 1
            }
        }
        return alias
    }

    /// Phase 8 chained dispatch: encode `nodes` into one render
    /// pass via `RenderBackend.executeChain`. The first node's
    /// primary input feeds draw 0 (sampled), every subsequent
    /// cluster reads the running attachment via programmable
    /// blending. Only the chain tail's destination texture is
    /// physically materialised; chain-internal cluster IDs alias
    /// to the same texture in `allocation.mapping` (set up by
    /// `LifetimeAwareTextureAllocator` from the
    /// `chainInternalAlias` dict in `tryCompilerPath`), so no
    /// phantom intermediate buckets are dispensed from the pool.
    private func dispatchFragmentChain(
        nodes: [Node],
        source: MTLTexture,
        allocation: LifetimeAwareTextureAllocator.Allocation,
        globalAdditional: [MTLTexture],
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let head = nodes.first, let tail = nodes.last else { return }
        let primaryRef = head.inputs.first ?? .source
        let chainSource = try resolveCompilerInput(
            ref: primaryRef,
            source: source,
            allocation: allocation,
            globalAdditional: globalAdditional,
            context: head.debugLabel
        )
        guard let chainDestination = allocation.mapping[tail.id] else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: tail.debugLabel,
                reason: "allocator has no destination texture for chain tail node \(tail.id)"
            ))
        }

        // Resolve aux textures per-cluster (LUT3D needs its lut,
        // NormalBlend needs its overlay, etc.). Each entry is the
        // ordered list of aux MTLTextures referenced by that
        // cluster's `.additional(i)` refs.
        var clusterAux: [[MTLTexture]] = []
        clusterAux.reserveCapacity(nodes.count)
        for node in nodes {
            let auxRefs = Self.auxRefs(of: node)
            var resolved: [MTLTexture] = []
            for ref in auxRefs {
                resolved.append(try resolveCompilerInput(
                    ref: ref,
                    source: source,
                    allocation: allocation,
                    globalAdditional: globalAdditional,
                    context: node.debugLabel
                ))
            }
            clusterAux.append(resolved)
        }

        if DCRLogging.diagnosticPipelineLogging {
            DCRLogging.logger.debug(
                "chain detected",
                category: "PipelineCompiler",
                attributes: [
                    "length": "\(nodes.count)",
                    "head": head.debugLabel,
                    "tail": tail.debugLabel,
                ]
            )
        }
        try RenderBackend.executeChain(
            clusters: nodes,
            source: chainSource,
            destination: chainDestination,
            clusterAuxiliaryTextures: clusterAux,
            commandBuffer: commandBuffer,
            renderCache: uberRenderCache
        )
    }

    /// Pull a node's auxiliary `NodeRef` list (LUT, overlay, mask,
    /// per-cluster aux). Centralised so chain-aux resolution and
    /// per-node compute dispatch stay in sync.
    private static func auxRefs(of node: Node) -> [NodeRef] {
        switch node.kind {
        case let .pixelLocal(_, _, _, aux):              return aux
        case let .neighborRead(_, _, _, aux):            return aux
        case let .fusedPixelLocalCluster(_, _, aux):     return aux
        default:                                          return []
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
                    uniformPool: uniformPool,
                    library: shaderLibrary
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
            uberCache: uberKernelCache,
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
            texturePool: texturePool,
            library: shaderLibrary
        )
    }
}

// MARK: - Multi-Pipeline factories

@available(iOS 18.0, *)
extension Pipeline {

    /// Create a Pipeline with **independent resource budgets** but
    /// **shared compilation caches**. The standard pattern for running
    /// multiple Pipelines concurrently — e.g. camera preview in one
    /// tab + photo editor in another, or live preview + export running
    /// at the same time.
    ///
    /// **What's isolated** (each Pipeline gets its own):
    /// - `TexturePool` — independent memory budget
    /// - `CommandBufferPool` — independent in-flight CB limit
    /// - `UniformBufferPool` — independent uniform-slot ring buffer
    ///
    /// **What's shared** (uses the SDK-wide `.shared` instances):
    /// - `Device`, `TextureLoader` — single GPU per process; stateless
    /// - `PipelineStateCache`, `UberKernelCache`, `UberRenderPipelineCache` —
    ///   PSO sharing is a perf win (compile once, reuse), and the cache
    ///   keys include library identity so different shader libraries
    ///   don't collide
    /// - `SamplerCache` — sampler descriptors are immutable
    /// - `ShaderLibrary.shared` — most apps use the SDK's built-in
    ///   shader bundle; if you register custom shaders dynamically and
    ///   need name-isolation across Pipelines, use
    ///   ``makeFullyIsolated(...)`` instead
    ///
    /// - Parameters:
    ///   - device: GPU device. Defaults to ``Device/shared``.
    ///   - textureBudgetMB: Maximum bytes (in MiB) for this Pipeline's
    ///     intermediate texture cache. Choose by intermediate size:
    ///     ~16 MiB for camera preview (1080p single-pass), 32-64 MiB
    ///     for editing preview (4K multi-pass), 128-256 MiB for export.
    ///   - maxInFlightCommandBuffers: Concurrent in-flight CBs.
    ///     30/60 fps preview wants 2-3; one-shot export wants 1.
    ///   - uniformPoolCapacity: Number of `MTLBuffer` slots in the
    ///     uniform pool's ring. 4 is fine for most cases; raise if
    ///     you have many distinct uniform structs being bound rapidly
    ///     (e.g. high-frequency slider drags across 6+ filters).
    ///   - uniformBufferSize: Bytes per uniform-pool buffer slot.
    ///     256 covers all SDK-shipped filter uniforms; raise only if
    ///     you ship custom filters with > 256 byte uniforms.
    ///   - optimization: Compiler optimisation mode. Defaults to `.full`.
    ///   - intermediatePixelFormat: Intermediate texture format.
    ///     Defaults to `.rgba16Float`.
    ///   - colorSpace: Numerical-domain mode. Defaults to
    ///     ``DCRenderKit/defaultColorSpace``.
    public static func makeIsolated(
        device: Device = .shared,
        textureBudgetMB: Int,
        maxInFlightCommandBuffers: Int = 3,
        uniformPoolCapacity: Int = 4,
        uniformBufferSize: Int = 256,
        optimization: PipelineOptimization = .full,
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) -> Pipeline {
        Pipeline(
            optimization: optimization,
            intermediatePixelFormat: intermediatePixelFormat,
            colorSpace: colorSpace,
            device: device,
            textureLoader: .shared,
            psoCache: .shared,
            uniformPool: UniformBufferPool(
                device: device,
                capacity: uniformPoolCapacity,
                bufferSize: uniformBufferSize
            ),
            samplerCache: .shared,
            texturePool: TexturePool(
                device: device,
                maxBytes: textureBudgetMB * 1024 * 1024
            ),
            commandBufferPool: CommandBufferPool(
                device: device,
                maxInFlight: maxInFlightCommandBuffers
            ),
            shaderLibrary: .shared,
            uberKernelCache: .shared,
            uberRenderCache: .shared
        )
    }

    /// Create a Pipeline with **fully independent resources** — every
    /// pool, cache, and shader library is a fresh instance. Designed
    /// for tests and rare scenarios where shader-name conflicts or
    /// PSO-cache observation require complete isolation.
    ///
    /// Production code should prefer ``makeIsolated(...)`` (which
    /// shares PSO caches for compile-time amortisation) or the
    /// default ``init()`` (which shares everything via `.shared`).
    ///
    /// - Parameters: Same as ``makeIsolated(...)``.
    public static func makeFullyIsolated(
        device: Device = .shared,
        textureBudgetMB: Int,
        maxInFlightCommandBuffers: Int = 3,
        uniformPoolCapacity: Int = 4,
        uniformBufferSize: Int = 256,
        optimization: PipelineOptimization = .full,
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float,
        colorSpace: DCRColorSpace = DCRenderKit.defaultColorSpace
    ) -> Pipeline {
        Pipeline(
            optimization: optimization,
            intermediatePixelFormat: intermediatePixelFormat,
            colorSpace: colorSpace,
            device: device,
            textureLoader: TextureLoader(device: device),
            psoCache: PipelineStateCache(device: device),
            uniformPool: UniformBufferPool(
                device: device,
                capacity: uniformPoolCapacity,
                bufferSize: uniformBufferSize
            ),
            samplerCache: SamplerCache(device: device),
            texturePool: TexturePool(
                device: device,
                maxBytes: textureBudgetMB * 1024 * 1024
            ),
            commandBufferPool: CommandBufferPool(
                device: device,
                maxInFlight: maxInFlightCommandBuffers
            ),
            shaderLibrary: ShaderLibrary(),
            uberKernelCache: UberKernelCache(device: device),
            uberRenderCache: UberRenderPipelineCache(device: device)
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
    if DCRLogging.diagnosticPipelineLogging {
        // Approximate bytes via the first texture's area × rough bpp —
        // the deferred set is typically homogeneous for a given graph,
        // and this signal exists only to cross-check with the
        // allocator's `peakBytes` line above; precision isn't critical.
        let totalBytes = textures.reduce(0) { acc, t in
            acc + (t.width * t.height * 8)
        }
        DCRLogging.logger.debug(
            "deferred enqueue scheduled",
            category: "PipelineMem",
            attributes: [
                "textures": "\(textures.count)",
                "approxBytes": "\(totalBytes)",
                "approxMB": String(format: "%.1f", Double(totalBytes) / (1024 * 1024)),
            ]
        )
    }
    // Box to satisfy `@Sendable` closure capture. `MTLTexture` is not
    // Sendable in Swift 6, but we only access it from the completion
    // callback (serial after GPU completion) and only hand it to
    // `pool.enqueue`, which is thread-safe via NSLock.
    let box = DeferredEnqueueBox(textures: textures, pool: pool)
    commandBuffer.addCompletedHandler { _ in
        box.flush()
        if DCRLogging.diagnosticPipelineLogging {
            DCRLogging.logger.debug(
                "pool post-completion",
                category: "PipelineMem",
                attributes: [
                    "poolBytes": "\(pool.currentBytes)",
                    "poolTextures": "\(pool.cachedTextureCount)",
                    "poolBuckets": "\(pool.bucketCount)",
                ]
            )
        }
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
