//
//  PipelineBenchmark.swift
//  DCRenderKit
//
//  SDK-internal benchmarking primitive. Measures end-to-end pipeline
//  GPU execution time using Metal's `MTLCommandBuffer.gpuStartTime`
//  / `gpuEndTime` — no Instruments, no external tooling required.
//
//  The measurement is deliberately "whole chain" rather than "per
//  filter": per-pass profiling demands `MTLCounterSampleBuffer`
//  plumbing across every dispatcher, which warps the API surface
//  for a diagnostic that most consumers (and most regression tests)
//  don't need. Whole-chain timing answers "did the chain get slower
//  this week", which is the point.
//

import Foundation
import Metal

/// GPU wall-clock timing for a filter pipeline.
///
/// ## Usage
///
/// ```swift
/// let result = try PipelineBenchmark.measureChainTime(
///     source: texture,
///     steps: [.single(ExposureFilter(exposure: 20)),
///             .multi(SoftGlowFilter(strength: 30))],
///     iterations: 20
/// )
/// print("median: \(result.medianMs) ms, p95: \(result.p95Ms) ms")
/// ```
///
/// ## Measurement design
///
/// - **Warmup** iterations populate the PSO cache, texture pool, and
///   any lazy-init state the pipeline touches. The first run of
///   anything in Metal pays compile cost (~10-100 ms per new PSO);
///   we don't want that in the sample.
/// - Each **measurement** iteration creates a fresh command buffer,
///   encodes the pipeline into it, commits, waits for completion,
///   and reads `gpuEndTime - gpuStartTime` (seconds). This is the
///   GPU's own clock — CPU-side overhead (encoding, Swift bookkeeping)
///   is excluded.
/// - Stats: median is the primary number (robust to outliers);
///   `p95Ms` captures tail latency that matters for realtime
///   pipelines; `minMs` / `maxMs` / `stdDevMs` give enough to spot
///   cache / thermal variability.
///
/// ## Threading
///
/// The method is synchronous — it blocks on `waitUntilCompleted`
/// for each iteration. Callers that want to run benchmarks off the
/// main thread should dispatch this call to a background queue.
public struct PipelineBenchmark: Sendable {

    /// Result of a timing run. All times are in milliseconds.
    public struct Result: Sendable {
        /// Number of measurement iterations that actually ran
        /// (warmup iterations are not counted).
        public let iterationsMeasured: Int
        /// Median GPU wall-clock time across the measured iterations.
        /// Robust to outliers (unlike the mean) and is the number to
        /// quote when comparing two runs.
        public let medianMs: Double
        /// 95th-percentile GPU wall-clock time. Captures tail latency
        /// that the median hides; relevant for real-time pipelines
        /// where the *slowest* frame determines the frame budget.
        public let p95Ms: Double
        /// Minimum GPU wall-clock time observed. Useful as a lower
        /// bound on achievable throughput on the measurement host.
        public let minMs: Double
        /// Maximum GPU wall-clock time observed. Indicates worst-case
        /// thermal / cache / scheduling variability during the run.
        public let maxMs: Double
        /// Sample standard deviation of GPU wall-clock times.
        /// High stddev at an otherwise stable median suggests the
        /// host is thermally throttling or the pipeline is
        /// contending with external Metal work.
        public let stdDevMs: Double

        /// Comma-separated row suitable for logging or test output.
        public var summary: String {
            String(format: "n=%d  median=%.3fms  p95=%.3fms  min=%.3fms  max=%.3fms  σ=%.3fms",
                   iterationsMeasured, medianMs, p95Ms, minMs, maxMs, stdDevMs)
        }
    }

    /// Measure how long `steps` take on the GPU when applied to
    /// `source`, averaged over `iterations` samples.
    ///
    /// - Parameters:
    ///   - source: The input texture. Re-used across iterations;
    ///     the source must have `.shaderRead` usage (same as any
    ///     ordinary pipeline input).
    ///   - steps: The filter chain to benchmark.
    ///   - iterations: Number of measured iterations (default 10).
    ///     Clamped to `[1, 1000]`.
    ///   - warmupIterations: Number of throwaway iterations to run
    ///     before measurement (default 2). Clamped to `[0, 100]`.
    ///   - device / pools: Dependency injection points — default to
    ///     the shared instances.
    /// - Returns: Measurement statistics.
    /// - Throws: Any `PipelineError` the underlying pipeline would
    ///   throw (texture allocation / PSO compile / GPU execution).
    public static func measureChainTime(
        source: MTLTexture,
        steps: [AnyFilter],
        iterations: Int = 10,
        warmupIterations: Int = 2,
        device: Device = .shared,
        textureLoader: TextureLoader = .shared,
        psoCache: PipelineStateCache = .shared,
        uniformPool: UniformBufferPool = .shared,
        samplerCache: SamplerCache = .shared,
        texturePool: TexturePool = .shared,
        commandBufferPool: CommandBufferPool = .shared
    ) throws -> Result {
        let measurementCount = max(1, min(iterations, 1000))
        let warmupCount = max(0, min(warmupIterations, 100))

        let pipeline = Pipeline(
            input: .texture(source),
            steps: steps,
            optimizer: FilterGraphOptimizer(),
            intermediatePixelFormat: .rgba16Float,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: texturePool,
            commandBufferPool: commandBufferPool
        )

        // Warmup.
        for _ in 0..<warmupCount {
            _ = try pipeline.outputSync()
        }

        // Measure.
        var samplesMs: [Double] = []
        samplesMs.reserveCapacity(measurementCount)
        for _ in 0..<measurementCount {
            let commandBuffer = try commandBufferPool.makeCommandBuffer(
                label: "DCR.Benchmark"
            )
            _ = try pipeline.encode(into: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error {
                throw PipelineError.device(.gpuExecutionFailed(underlying: error))
            }
            let seconds = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
            samplesMs.append(seconds * 1000.0)
        }

        return makeResult(samplesMs: samplesMs)
    }

    // MARK: - Statistics

    private static func makeResult(samplesMs raw: [Double]) -> Result {
        guard !raw.isEmpty else {
            return Result(
                iterationsMeasured: 0,
                medianMs: 0, p95Ms: 0, minMs: 0, maxMs: 0, stdDevMs: 0
            )
        }
        let sorted = raw.sorted()
        let count = sorted.count

        let median: Double = {
            if count.isMultiple(of: 2) {
                let lo = sorted[count / 2 - 1]
                let hi = sorted[count / 2]
                return (lo + hi) / 2
            }
            return sorted[count / 2]
        }()

        let p95Index = max(0, Int((Double(count) * 0.95).rounded(.down)) - 1)
        let p95 = sorted[min(p95Index, count - 1)]

        let minMs = sorted.first ?? 0
        let maxMs = sorted.last ?? 0
        let mean = sorted.reduce(0, +) / Double(count)
        let variance = sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count)
        let stdDev = variance.squareRoot()

        return Result(
            iterationsMeasured: count,
            medianMs: median,
            p95Ms: p95,
            minMs: minMs,
            maxMs: maxMs,
            stdDevMs: stdDev
        )
    }
}
