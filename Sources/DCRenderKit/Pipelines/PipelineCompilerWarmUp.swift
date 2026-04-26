//
//  PipelineCompilerWarmUp.swift
//  DCRenderKit
//
//  Phase 5 step 5.6 — SDK-provided warm-up API for the pipeline
//  compiler's runtime-generated uber kernels.
//
//  Every uber kernel is a runtime-compiled `MTLLibrary` + PSO pair
//  keyed by a deterministic hash over the fused body sequence. First-
//  time compilation takes ~100-200 ms per kernel on a modern Apple
//  GPU; subsequent dispatches are an O(1) cache lookup. The warm-up
//  API lets an app perform that one-time compile cost at launch (on
//  a background thread) so the first frame of live preview is a
//  guaranteed cache hit.
//
//  See `docs/pipeline-compiler-design.md` §6.4 for the full design
//  rationale.
//

import Foundation
import Metal

/// SDK-provided warm-up hook for the pipeline compiler's uber kernel
/// cache.
///
/// Typical call site: after the first frame is drawn, kick off a
/// detached `Task` that invokes ``preheat(combinations:intermediatePixelFormat:)``
/// with every `[AnyFilter]` combination the app expects to encounter.
/// The compiler lowers each combination, runs the optimiser, and
/// compiles every resulting uber kernel into
/// ``UberKernelCache/shared`` — but does **not** allocate textures,
/// encode commands, or dispatch work.
///
/// ```swift
/// @MainActor
/// func appDidFinishLaunching() {
///     Task.detached(priority: .utility) {
///         try? await PipelineCompilerWarmUp.preheat(combinations: [
///             // Tone preset 1
///             [.single(ExposureFilter()),
///              .single(ContrastFilter()),
///              .single(SaturationFilter())],
///             // Tone preset 2 + sharpen
///             [.single(ExposureFilter()),
///              .single(ContrastFilter()),
///              .single(SharpenFilter(amount: 30, step: 1))],
///         ])
///     }
/// }
/// ```
///
/// Each combination pays `O(N_uber_kernels × compile_time)` on first
/// warm-up and zero cost on every subsequent `Pipeline.encode(...)` /
/// `Pipeline.processSync(...)` that targets a cache-compatible graph.
///
/// Cache identity: the compiler names every uber kernel by a
/// deterministic hash of the fused body sequence plus signature
/// shape — uniform values are excluded. A warm-up call made with
/// slider values of 0 therefore populates the same cache entry that
/// a runtime chain with slider values of +50 would hit. You don't
/// need to preheat every slider combination; one canonical pass per
/// filter topology is sufficient.
@available(iOS 18.0, *)
public enum PipelineCompilerWarmUp {

    /// Compile every uber-kernel PSO required by `combinations`,
    /// populating ``UberKernelCache/shared`` so the first runtime
    /// dispatch of each combination is a cache hit.
    ///
    /// - Parameters:
    ///   - combinations: Filter chains to warm up. Each inner array
    ///     is a complete chain (the same shape you'd pass as `steps:`
    ///     to `Pipeline.encode(...)` / `Pipeline.processSync(...)`).
    ///   - intermediatePixelFormat: Pixel format used to resolve the
    ///     allocator's `TextureInfo`. Defaults to the SDK default
    ///     `.rgba16Float`. Warm-up compiles are not sensitive to the
    ///     format — the uber kernel hashes exclude it — but any
    ///     multi-pass filter in a combination lowers its passes
    ///     against this info, so it matches what `Pipeline` threads
    ///     through at runtime.
    ///
    /// - Throws: `MetalSourceBuilder.BuildError` on codegen failure;
    ///   `PipelineError.pipelineState(.computeCompileFailed)` on
    ///   Metal library compilation failure.
    ///
    /// The call is `async` to keep the signature future-proof (the
    /// current implementation compiles synchronously on the caller's
    /// thread, but a later revision may parallelise across kernels),
    /// and because shipping a synchronous version would tempt
    /// consumers to call it from the main thread at launch — exactly
    /// the pattern this API is meant to prevent.
    public static func preheat(
        combinations: [[AnyFilter]],
        intermediatePixelFormat: MTLPixelFormat = .rgba16Float
    ) async throws {
        // A canonical placeholder source info. Single-pass lowerings
        // ignore the width / height (they only use the source's
        // modifier + fusion body), and multi-pass lowerings need a
        // value to resolve adaptive pass counts — 1920 × 1080 is a
        // reasonable default for the "common combinations warmed at
        // launch" use case. Consumers who need a different size can
        // call `preheat` once per size; uber-kernel hashes exclude
        // the texture dimensions, so same-topology calls collide in
        // the cache regardless.
        let source = TextureInfo(
            width: 1920,
            height: 1080,
            pixelFormat: intermediatePixelFormat
        )

        for combination in combinations {
            try preheatOne(combination, source: source)
            // Yield between combinations so the warm-up task doesn't
            // monopolise the priority-inheriting executor if the
            // caller ran us on .userInitiated.
            await Task.yield()
        }
    }

    // MARK: - Private

    /// Compile every uber-kernel PSO needed for a single combination.
    /// Skips nodes the compiler can't codegen today
    /// (`.nativeCompute`, resolution changes) — those fall through to
    /// the legacy `ComputeDispatcher` path at runtime and warm their
    /// PSOs on first dispatch.
    private static func preheatOne(
        _ combination: [AnyFilter],
        source: TextureInfo
    ) throws {
        guard let lowered = Lowering.lower(combination, source: source) else {
            // Non-lowerable chain (render / blit / MPS single-pass
            // or multi-pass with a non-compute pass). Nothing to
            // warm on the compiler path.
            return
        }
        let graph = Optimizer.optimize(lowered)

        for node in graph.nodes {
            switch node.kind {
            case .pixelLocal, .neighborRead, .fusedPixelLocalCluster:
                try compileUberKernel(for: node)
            default:
                // `.nativeCompute` / `.downsample` / `.upsample` /
                // `.reduce` / `.blend` — not a `MetalSourceBuilder`
                // shape yet. Warms on first runtime dispatch through
                // the fallback path.
                continue
            }
        }
    }

    /// Run the Phase-3 codegen for `node` and shove the resulting
    /// PSO into the shared cache. Subsequent runtime calls that
    /// hash to the same function name are cache hits.
    private static func compileUberKernel(for node: Node) throws {
        let build = try MetalSourceBuilder.build(for: node)
        _ = try UberKernelCache.shared.pipelineState(
            source: build.source,
            functionName: build.functionName
        )
    }
}
