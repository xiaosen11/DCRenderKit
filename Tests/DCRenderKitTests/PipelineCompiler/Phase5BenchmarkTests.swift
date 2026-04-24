//
//  Phase5BenchmarkTests.swift
//  DCRenderKitTests
//
//  Phase 5 step 5.7 — GPU benchmark comparing the compiler's
//  `.full` fusion path against the per-node `.none` path on a
//  representative four-filter pixel-local chain. Runs locally on
//  the CI host (macOS) to detect regressions in the fusion
//  pipeline; the user-gate real-device verification happens on an
//  iPhone 14 Pro Max using the harness in this file (see
//  `logFullVsNoneTimings` — it emits a row the user can paste into
//  `docs/pipeline-compiler-handoff.md`).
//
//  The test asserts two invariants:
//
//   1. `.full` path compiles exactly one uber kernel for the
//      four-filter chain (the fused cluster) while `.none` compiles
//      four (one per filter).
//   2. Both paths complete without error on an isolated pool so
//      the harness is safe to re-run for tuning.
//
//  GPU wall-clock times are logged but NOT asserted: CI hosts
//  (Intel Mac, Apple Silicon Mac, self-hosted runners, etc.) have
//  widely varying absolute numbers and thermal states. The real
//  timing gate lives on the user's iPhone.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class Phase5BenchmarkTests: XCTestCase {

    private var device: Device!
    private var psoCache: PipelineStateCache!
    private var uniformPool: UniformBufferPool!
    private var samplerCache: SamplerCache!
    private var texturePool: TexturePool!
    private var commandBufferPool: CommandBufferPool!
    private var textureLoader: TextureLoader!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 4, bufferSize: 256)
        samplerCache = SamplerCache(device: d)
        texturePool = TexturePool(device: d, maxBytes: 128 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)
        UberKernelCache.shared.clear()
    }

    override func tearDown() {
        commandBufferPool = nil
        texturePool = nil
        samplerCache = nil
        uniformPool = nil
        psoCache = nil
        textureLoader = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Verify the step-5.7 benchmark harness compiles the expected
    /// number of uber kernels under `.full` (one fused cluster) and
    /// `.none` (one per filter) for a four-filter pixel-local chain,
    /// and log the GPU wall-clock timing rows so the user-gate
    /// iPhone run can be compared against them.
    func testFullModeFusesFourFilterChainIntoOneUberKernel() throws {
        let source = try makeSolidTexture(width: 1080, height: 1080, red: 0.5)
        let steps = representativeToneChain()

        // Warm + measure .full.
        UberKernelCache.shared.clear()
        let fullResult = try runBenchmark(source: source, steps: steps, optimization: .full)
        let fullKernels = UberKernelCache.shared.cachedPipelineCount

        // Warm + measure .none.
        UberKernelCache.shared.clear()
        let noneResult = try runBenchmark(source: source, steps: steps, optimization: .none)
        let noneKernels = UberKernelCache.shared.cachedPipelineCount

        XCTAssertEqual(
            fullKernels, 1,
            ".full mode should collapse the four pixel-local filters into a single uber kernel; got \(fullKernels)."
        )
        XCTAssertEqual(
            noneKernels, 4,
            ".none mode should compile one uber kernel per filter; got \(noneKernels)."
        )

        logFullVsNoneTimings(
            chainDescription: "Exposure → Contrast → Blacks → Whites @ 1080x1080",
            full: fullResult, fullKernels: fullKernels,
            none: noneResult, noneKernels: noneKernels
        )
    }

    // MARK: - Fixtures

    /// Four filters that all declare `wantsLinearInput = false` so
    /// `VerticalFusion` can legally merge them into one cluster.
    /// A mixed-linearity chain (e.g., one including Saturation or
    /// Vibrance) would split into two clusters, which is the right
    /// behaviour but hides the flagship fusion win we want to
    /// surface here.
    private func representativeToneChain() -> [AnyFilter] {
        [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 15, lumaMean: 0.5)),
            .single(BlacksFilter(blacks: 10)),
            .single(WhitesFilter(whites: 5)),
        ]
    }

    private func runBenchmark(
        source: MTLTexture,
        steps: [AnyFilter],
        optimization: PipelineOptimization
    ) throws -> PipelineBenchmark.Result {
        try PipelineBenchmark.measureChainTime(
            source: source,
            steps: steps,
            iterations: 8,
            warmupIterations: 2,
            optimization: optimization,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: texturePool,
            commandBufferPool: commandBufferPool
        )
    }

    private func makeSolidTexture(
        width: Int, height: Int,
        red: Float, green: Float = 0.0, blue: Float = 0.0, alpha: Float = 1.0
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let hr = Float16(red).bitPattern
        let hg = Float16(green).bitPattern
        let hb = Float16(blue).bitPattern
        let ha = Float16(alpha).bitPattern
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = hr
            pixels[i * 4 + 1] = hg
            pixels[i * 4 + 2] = hb
            pixels[i * 4 + 3] = ha
        }
        pixels.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 8
            )
        }
        return tex
    }

    private func logFullVsNoneTimings(
        chainDescription: String,
        full: PipelineBenchmark.Result,
        fullKernels: Int,
        none: PipelineBenchmark.Result,
        noneKernels: Int
    ) {
        let speedup = none.medianMs / max(full.medianMs, 0.0001)
        print("""

        ================================================================
        Phase-5 benchmark — \(chainDescription)
        ----------------------------------------------------------------
        .full (compiler + fusion)
          uber kernels compiled: \(fullKernels)
          \(full.summary)

        .none (compiler, no fusion)
          uber kernels compiled: \(noneKernels)
          \(none.summary)

        Fusion speedup (none/full median): \(String(format: "%.2fx", speedup))
        ================================================================

        """)
    }
}
