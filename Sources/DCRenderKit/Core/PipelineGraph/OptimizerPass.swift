//
//  OptimizerPass.swift
//  DCRenderKit
//
//  Phase-2 optimiser framework. An `OptimizerPass` is a pure
//  function from `PipelineGraph` to `PipelineGraph`; passes run in
//  a fixed sequence defined by `Optimizer.defaultPasses`. Every
//  pass is `internal` — the IR itself isn't public (see
//  `docs/pipeline-compiler-design.md` §1.2), so neither are the
//  transformations that operate on it.
//
//  Each concrete pass lives in its own file under this directory
//  (`DeadCodeElimination.swift`, `VerticalFusion.swift`, …) and
//  has matching fixture-driven tests under
//  `Tests/DCRenderKitTests/PipelineCompiler/`.
//

import Foundation

/// Contract every optimiser pass satisfies.
///
/// Passes are expected to be **pure**: they must not read or write
/// state outside their `run(_:)` parameter, must not depend on
/// runtime Metal state (that belongs to Phase 3's codegen / Phase 4's
/// allocator), and must produce a valid graph (if the pass rewrites
/// nodes, the result must satisfy `PipelineGraph.validate()`).
///
/// Passes may return the input graph unchanged when they find no
/// applicable transformation — this is cheaper than reconstructing
/// an identical graph and lets the pipeline-compiler log "N passes
/// reduced M nodes" accurately.
@available(iOS 18.0, *)
internal protocol OptimizerPass: Sendable {

    /// Human-readable name used by the compiler's debug log when
    /// announcing "ran pass X, before → after". Should be short
    /// (≤ 24 chars) and stable across builds.
    var name: String { get }

    /// Transform `graph` into an equivalent-or-better graph.
    ///
    /// "Equivalent" means the pass preserves the final-output
    /// semantics to Float16 margin — this is exercised in Phase 3's
    /// legacy-parity tests. "Better" means one of:
    /// fewer nodes, fewer dispatches, less intermediate memory, or
    /// more fusion opportunities downstream. A pass that performs
    /// no transformation returns `graph` verbatim.
    func run(_ graph: PipelineGraph) -> PipelineGraph
}

// MARK: - Optimizer orchestrator

/// Runs the default optimisation sequence. The list is intentionally
/// fixed — every pass interacts with its predecessors and
/// successors in known ways (see design doc §5). Rearranging the
/// order without coordinated updates elsewhere will produce
/// incorrect graphs.
///
/// `Optimizer.optimize` is the production entry point; tests may
/// bypass the orchestrator to exercise individual passes in
/// isolation.
@available(iOS 18.0, *)
internal enum Optimizer {

    /// The fixed sequence of Phase-2 passes. Exact order:
    ///
    ///   1. DeadCodeElimination             — drop unreachable nodes
    ///   2. VerticalFusion                  — merge adjacent pixelLocal
    ///   3. CommonSubexpressionElimination  — share identical work
    ///   4. KernelInlining                  — sink pixelLocal into
    ///                                        neighborRead sample
    ///                                        points
    ///   5. TailSink                        — sink downstream body into
    ///                                        multi-pass final
    ///   6. ResolutionFolding               — mark alias candidates
    ///
    /// Lands in this file incrementally as each pass is implemented;
    /// later Phase-2 steps append to this list.
    nonisolated(unsafe) internal static var defaultPasses: [any OptimizerPass] = [
        DeadCodeElimination(),
        VerticalFusion(),
        CommonSubexpressionElimination(),
        KernelInlining(),
    ]

    /// Run every pass in `defaultPasses` against `graph`, in order.
    /// Returns the fully-optimised graph.
    static func optimize(_ graph: PipelineGraph) -> PipelineGraph {
        defaultPasses.reduce(graph) { current, pass in
            pass.run(current)
        }
    }
}
