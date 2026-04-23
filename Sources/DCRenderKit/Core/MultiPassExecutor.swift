//
//  MultiPassExecutor.swift
//  DCRenderKit
//
//  Compiles a declarative `[Pass]` graph into an actual GPU execution
//  sequence. Handles topological ordering, intermediate texture allocation
//  via the TexturePool, and lifetime analysis so unused textures are
//  reclaimed as early as possible.
//
//  This is the runtime companion to `MultiPassFilter`. Filters declare
//  *what* should happen; `MultiPassExecutor` figures out *how* — including
//  when each intermediate texture can be released.
//

import Foundation
import Metal

/// Executes a declarative multi-pass compute graph on the GPU.
///
/// ## Why this exists
///
/// Harbeth's `C7CombinationBase.prepareIntermediateTextures()` requires every
/// multi-pass filter (SoftGlow, Clarity, HighlightShadow, etc) to manually:
/// 1. Allocate each intermediate texture
/// 2. Schedule each sub-kernel
/// 3. Track texture lifetimes and release manually
/// 4. Handle cleanup in `combinationAfter`
///
/// This is ~80 lines of boilerplate per filter, error-prone (leaks are easy),
/// and prevents dynamic pass counts (e.g. adaptive pyramid depth).
///
/// `MultiPassExecutor` lifts all of that into the framework. Filters declare
/// `passes(input:) -> [Pass]` and the framework handles the rest.
///
/// ## Compute-only by design
///
/// The executor handles only `.compute` passes. Multi-pass workflows in
/// image processing (pyramids, guided filters, bloom, local tonemapping)
/// are all compute-based. Render passes are reserved for single-pass
/// filters (stickers, distortion meshes) where the pipeline includes
/// vertex buffers and draw primitives that don't fit the DAG model.
///
/// If a future use case needs mixed compute+render multi-pass, the
/// executor can be extended. Until then, simplicity beats generality.
public struct MultiPassExecutor {

    /// Execute a pass graph, returning the final output texture.
    ///
    /// - Parameters:
    ///   - passes: The DAG declared by `MultiPassFilter.passes(input:)`.
    ///     Must contain exactly one pass with `isFinal = true`. Empty arrays
    ///     short-circuit to returning `source` directly (identity).
    ///   - source: The filter's input texture (referenced as `.source` in
    ///     pass inputs).
    ///   - intermediatePixelFormat: Pixel format used to allocate every
    ///     intermediate texture that backs a pass output. The source
    ///     texture's own `pixelFormat` is **not** used for this — a camera
    ///     feed in `bgra8Unorm` still produces `rgba16Float` intermediates
    ///     when the pipeline asks for float precision. Required to prevent
    ///     8-bit quantization from silently truncating bloom accumulation,
    ///     HighlightShadow ratios > 1.0, or Clarity's 1/255-step residuals.
    ///   - commandBuffer: Buffer to encode all dispatches into.
    ///   - psoCache: PSO cache (default shared).
    ///   - uniformPool: Uniform buffer pool (default shared).
    ///   - texturePool: Texture pool used for intermediate allocations
    ///     (default shared). Intermediate textures are automatically
    ///     returned to the pool as soon as they go out of use. The final
    ///     output is NOT returned — its lifetime is handed to the caller.
    /// - Returns: The output texture produced by the pass with `isFinal=true`.
    /// - Throws: `PipelineError.filter(.invalidPassGraph)` for graph
    ///   validation failures; `PipelineError.filter(.emptyPassGraph)` if
    ///   `passes` is empty AND `source` should not be returned directly;
    ///   various texture/PSO errors propagated from the dispatchers.
    public static func execute(
        passes: [Pass],
        source: MTLTexture,
        additionalInputs: [MTLTexture] = [],
        intermediatePixelFormat: MTLPixelFormat,
        commandBuffer: MTLCommandBuffer,
        psoCache: PipelineStateCache = .shared,
        uniformPool: UniformBufferPool = .shared,
        texturePool: TexturePool = .shared
    ) throws -> MTLTexture {
        // Empty graph = identity; return source unchanged.
        if passes.isEmpty {
            return source
        }

        // 1. Validate graph structure
        try validate(passes: passes)

        // 2. Compute last-use step for each texture (for early release)
        let lastUse = computeLastUseSteps(passes: passes)

        // 3. Resolve each pass's output info (needed when later passes
        //    reference earlier ones via `.matching`).
        //    The sourceInfo carries the INTERMEDIATE format, not
        //    `source.pixelFormat` — `TextureSpec.resolve` propagates this
        //    format into every pass output, which is the contract the
        //    Pipeline's `intermediatePixelFormat` promises.
        var resolvedInfos: [String: TextureInfo] = [:]
        let sourceInfo = TextureInfo(
            width: source.width,
            height: source.height,
            pixelFormat: intermediatePixelFormat
        )

        // 4. Execute in declaration order
        var produced: [String: MTLTexture] = [:]
        var finalOutput: MTLTexture?
        // Intermediates collected here are returned to the pool only
        // after the command buffer completes on the GPU — see
        // `scheduleDeferredEnqueue`.
        var pendingEnqueue: [MTLTexture] = []

        for (stepIndex, pass) in passes.enumerated() {
            // Resolve output dimensions.
            guard let outputInfo = pass.output.resolve(
                source: sourceInfo,
                resolvedPeers: resolvedInfos
            ) else {
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: "MultiPass",
                    reason: "Pass '\(pass.name)' has unresolvable output spec"
                ))
            }
            resolvedInfos[pass.name] = outputInfo

            // Allocate output texture from pool.
            let outputTexture = try texturePool.dequeue(spec: TexturePoolSpec(
                width: outputInfo.width,
                height: outputInfo.height,
                pixelFormat: outputInfo.pixelFormat,
                usage: [.shaderRead, .shaderWrite],
                storageMode: .private
            ))

            // Resolve input textures.
            let (sourceInput, passAdditionalInputs) = try resolveInputs(
                pass: pass,
                source: source,
                additionalInputs: additionalInputs,
                produced: produced
            )

            // Dispatch based on modifier.
            switch pass.modifier {
            case .compute(let kernel):
                try ComputeDispatcher.dispatch(
                    kernel: kernel,
                    uniforms: pass.uniforms,
                    additionalInputs: passAdditionalInputs,
                    source: sourceInput,
                    destination: outputTexture,
                    commandBuffer: commandBuffer,
                    psoCache: psoCache,
                    uniformPool: uniformPool
                )

            case .render, .blit, .mps:
                // Release the allocated texture before throwing.
                texturePool.enqueue(outputTexture)
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: "MultiPass",
                    reason: "Pass '\(pass.name)' uses \(pass.modifier); only .compute is supported in multi-pass graphs"
                ))
            }

            // Record produced texture.
            produced[pass.name] = outputTexture

            // Check if this is the final output.
            if pass.isFinal {
                finalOutput = outputTexture
            }

            // Release intermediate textures whose last use is this step.
            // Never release the final output or the source (source is
            // caller-owned). "Release" here means: defer until the CB
            // completes on the GPU (see scheduleDeferredEnqueue); this
            // prevents cross-CB reuse of an in-flight texture.
            for (name, lastStep) in lastUse where lastStep == stepIndex {
                guard let texture = produced[name] else { continue }
                // Don't release the final output.
                if texture === finalOutput { continue }
                pendingEnqueue.append(texture)
                produced.removeValue(forKey: name)
            }
        }

        guard let output = finalOutput else {
            // Should be caught by validate(); belt-and-suspenders.
            throw PipelineError.filter(.invalidPassGraph(
                filterName: "MultiPass",
                reason: "No pass with isFinal=true was marked"
            ))
        }

        scheduleDeferredEnqueue(
            textures: pendingEnqueue,
            pool: texturePool,
            commandBuffer: commandBuffer
        )

        return output
    }

    // MARK: - Graph validation

    private static func validate(passes: [Pass]) throws {
        // 1. Exactly one final pass.
        let finalCount = passes.lazy.filter { $0.isFinal }.count
        guard finalCount == 1 else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: "MultiPass",
                reason: "expected exactly one pass with isFinal=true, got \(finalCount)"
            ))
        }

        // 2. Unique pass names.
        var seen = Set<String>()
        for pass in passes {
            if !seen.insert(pass.name).inserted {
                throw PipelineError.filter(.invalidPassGraph(
                    filterName: "MultiPass",
                    reason: "duplicate pass name '\(pass.name)'"
                ))
            }
        }

        // 3. Each named input must refer to a prior pass (declaration order
        //    is treated as topological order; forward references are cycles).
        var declaredSoFar = Set<String>()
        for pass in passes {
            for input in pass.inputs {
                if case .named(let referenced) = input {
                    if referenced == pass.name {
                        throw PipelineError.filter(.invalidPassGraph(
                            filterName: "MultiPass",
                            reason: "pass '\(pass.name)' references itself"
                        ))
                    }
                    if !declaredSoFar.contains(referenced) {
                        throw PipelineError.filter(.invalidPassGraph(
                            filterName: "MultiPass",
                            reason: "pass '\(pass.name)' references '\(referenced)' which is not declared earlier"
                        ))
                    }
                }
            }
            declaredSoFar.insert(pass.name)
        }
    }

    // MARK: - Lifetime analysis

    /// Compute the step index at which each named intermediate texture is
    /// last consumed. Used to release textures as early as possible.
    ///
    /// Returns a map from pass name → last step index (0-based) where the
    /// pass's output is used as an input. Passes whose output is only
    /// consumed by themselves won't appear in the map (the executor already
    /// handles that implicitly by never promoting them into `produced`).
    private static func computeLastUseSteps(passes: [Pass]) -> [String: Int] {
        var lastUse: [String: Int] = [:]
        for (stepIndex, pass) in passes.enumerated() {
            for input in pass.inputs {
                if case .named(let name) = input {
                    // This step consumes `name`, so `name`'s last-use index
                    // is at least `stepIndex`.
                    if let existing = lastUse[name] {
                        lastUse[name] = max(existing, stepIndex)
                    } else {
                        lastUse[name] = stepIndex
                    }
                }
            }
        }
        return lastUse
    }

    // MARK: - Input resolution

    private static func resolveInputs(
        pass: Pass,
        source: MTLTexture,
        additionalInputs: [MTLTexture],
        produced: [String: MTLTexture]
    ) throws -> (primary: MTLTexture, additional: [MTLTexture]) {
        guard !pass.inputs.isEmpty else {
            throw PipelineError.filter(.invalidPassGraph(
                filterName: "MultiPass",
                reason: "pass '\(pass.name)' has no inputs"
            ))
        }

        var textures: [MTLTexture] = []
        for input in pass.inputs {
            switch input {
            case .source:
                textures.append(source)
            case .named(let name):
                guard let tex = produced[name] else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: "MultiPass",
                        reason: "pass '\(pass.name)' references '\(name)' which was already released or never produced"
                    ))
                }
                textures.append(tex)
            case .additional(let index):
                guard index >= 0, index < additionalInputs.count else {
                    throw PipelineError.filter(.invalidPassGraph(
                        filterName: "MultiPass",
                        reason: "pass '\(pass.name)' references .additional(\(index)) but filter provided only \(additionalInputs.count) auxiliary textures"
                    ))
                }
                textures.append(additionalInputs[index])
            }
        }

        let primary = textures[0]
        let additional = Array(textures.dropFirst())
        return (primary, additional)
    }
}
