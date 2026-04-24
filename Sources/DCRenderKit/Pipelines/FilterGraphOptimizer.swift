//
//  FilterGraphOptimizer.swift
//  DCRenderKit
//
//  Transforms a filter chain into a (potentially) equivalent chain with
//  fewer passes by fusing adjacent filters that share a `fuseGroup`.
//
//  Phase 1 (Round 9): passthrough skeleton — no fusion performed yet.
//  Phase 2 (Round 20+): full implementation with ToneFilter and ColorFilter
//  fuse templates matching to eliminate 5 of the 6 per-pixel 8-bit
//  quantization steps on the standard adjustment chain.
//

import Foundation

/// Rewrites a filter chain to improve performance and precision.
///
/// ## Role
///
/// When a user declares a pipeline like
/// `[Exposure, Contrast, Whites, Blacks, ...]`, each filter runs as a
/// separate dispatch with an 8-bit intermediate texture between them.
/// That's five dispatches and four rounds of quantization for what is
/// mathematically a single per-pixel operation.
///
/// `FilterGraphOptimizer` identifies such runs of adjacent filters
/// declaring the same `fuseGroup` (e.g. `.toneAdjustment`) and replaces
/// them with a single uber-filter that runs all the math in one dispatch
/// with zero intermediate quantization.
///
/// ## Phase 1 stance
///
/// This Round 9 implementation is a **passthrough**: it returns the input
/// steps unchanged. Fusion is introduced in Phase 2 (Round 20) once we've
/// migrated the per-pixel filters and have real uber-kernels to fuse to
/// (`ToneFilter`, `ColorFilter`).
///
/// Keeping the optimizer as a stable public API from Round 9 means:
/// - The pipeline already plumbs filters through the optimizer, so Phase 2
///   can activate fusion without touching `Pipeline` code.
/// - Tests written in Round 9 for passthrough semantics continue to hold
///   (fusion must be semantically equivalent at pixel level).
/// - Debug logging of "fused N filters into M" can be wired up now and
///   start producing useful output the moment templates land.
@available(iOS 18.0, *)
public struct FilterGraphOptimizer {

    // MARK: - Configuration

    /// Whether to attempt fusion at all. Setting this to false forces a
    /// passthrough even when templates are available — useful for debugging
    /// to isolate whether an issue is caused by fusion or by an individual
    /// filter.
    public var isEnabled: Bool

    /// Whether to log optimization decisions at debug level.
    public var logsDecisions: Bool

    public init(isEnabled: Bool = true, logsDecisions: Bool = true) {
        self.isEnabled = isEnabled
        self.logsDecisions = logsDecisions
    }

    // MARK: - API

    /// Return a potentially optimized version of `steps`.
    ///
    /// Round 9: passthrough — returns `steps` unchanged.
    /// Phase 2: scans for adjacent same-fuseGroup filters and replaces
    /// them with registered `FuseTemplate` matches.
    public func optimize(_ steps: [AnyFilter]) -> [AnyFilter] {
        guard isEnabled else {
            return steps
        }

        // Phase 1 placeholder: no fusion performed yet.
        // Fusion logic lands in Phase 2 alongside ToneFilter and
        // ColorFilter templates.
        if logsDecisions, !steps.isEmpty {
            DCRLogging.logger.debug(
                "FilterGraphOptimizer: passthrough (Phase 1)",
                category: "FilterGraphOptimizer",
                attributes: ["stepCount": "\(steps.count)"]
            )
        }
        return steps
    }
}
