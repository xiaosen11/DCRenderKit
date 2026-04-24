//
//  Phase5PipelineIntegrationTests.swift
//  DCRenderKitTests
//
//  Phase-5 step 5.1 smoke tests: verify that `Pipeline.executeSinglePass`
//  now routes built-in filters (which carry `fusionBody` descriptors)
//  through `ComputeBackend` — i.e. the runtime-compiled uber kernel —
//  rather than through the legacy `ComputeDispatcher.dispatch(kernel:)`
//  path that looks up a standalone symbol in `ShaderLibrary`.
//
//  Test strategy:
//
//    1. Observe `UberKernelCache.shared.cachedPipelineCount` before
//       and after a `Pipeline.outputSync()` call. If the count grows
//       by exactly one uber kernel for a single-filter chain, the
//       codegen path was exercised.
//
//    2. For a chain of distinct pixel-local filters run individually
//       (`.full` optimiser behaviour is introduced in step 5.3; step
//       5.1 just wires each filter independently), the cache should
//       grow by one entry per distinct uber function name.
//
//    3. Output bytes should be finite and in gamut. We don't compare
//       against legacy here — `LegacyParityTests` already owns that
//       gate at the `ComputeBackend` level. This file demonstrates
//       only that `Pipeline` reaches that codegen path.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class Phase5PipelineIntegrationTests: XCTestCase {

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
        texturePool = TexturePool(device: d, maxBytes: 32 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)

        // Cached entries from prior tests would mask the codegen-
        // triggered growth we want to observe; clearing ensures the
        // delta is an unambiguous signal.
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

    /// A single built-in pixel-local filter routes through
    /// `ComputeBackend`: the shared uber-kernel cache gains exactly
    /// one entry after the pipeline runs.
    func testSingleBuiltInFilterReachesComputeBackendCodegen() throws {
        let source = try makeSolidTexture(width: 16, height: 16, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(ExposureFilter(exposure: 20))]
        )

        let before = UberKernelCache.shared.cachedPipelineCount
        let output = try pipeline.outputSync()
        let after = UberKernelCache.shared.cachedPipelineCount

        XCTAssertEqual(
            after - before, 1,
            "Expected exactly one uber-kernel PSO compiled for a single filter chain; got Δ=\(after - before)."
        )

        // Sanity check: output differs from the input (Exposure +20 is
        // non-identity) and is finite in-gamut.
        let px = try readFirstPixel(output)
        XCTAssertTrue(px.r.isFinite && px.g.isFinite && px.b.isFinite)
        XCTAssertGreaterThanOrEqual(px.r, 0)
        XCTAssertLessThanOrEqual(px.r, 1.0001)
    }

    /// With `.full` optimisation (the default), a three-filter
    /// pixel-local chain of matching signature shape runs through
    /// `VerticalFusion` and collapses into a single
    /// `.fusedPixelLocalCluster` node — therefore a single uber
    /// kernel at runtime. This is the flagship perf claim: "no matter
    /// how many filters you stack, the cost scales like one filter."
    func testThreeFilterChainFusesIntoOneClusterUnderFull() throws {
        let source = try makeSolidTexture(width: 16, height: 16, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
                .single(SaturationFilter(saturation: 1.2)),
            ],
            optimization: .full
        )

        let before = UberKernelCache.shared.cachedPipelineCount
        let output = try pipeline.outputSync()
        let after = UberKernelCache.shared.cachedPipelineCount

        XCTAssertEqual(
            after - before, 1,
            "VerticalFusion should collapse the three pixel-local filters into one cluster uber kernel; got Δ=\(after - before)."
        )

        let px = try readFirstPixel(output)
        XCTAssertTrue(px.r.isFinite && px.g.isFinite && px.b.isFinite)
    }

    /// With `.none` the optimiser is bypassed and each filter
    /// dispatches through its own uber kernel. Same chain, same
    /// output (modulo Float16 rounding), but three PSOs land in the
    /// cache instead of one.
    func testThreeFilterChainStaysSeparateUnderNone() throws {
        let source = try makeSolidTexture(width: 16, height: 16, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
                .single(SaturationFilter(saturation: 1.2)),
            ],
            optimization: .none
        )

        let before = UberKernelCache.shared.cachedPipelineCount
        _ = try pipeline.outputSync()
        let after = UberKernelCache.shared.cachedPipelineCount

        XCTAssertEqual(
            after - before, 3,
            "With optimisation disabled, the three filters must each compile their own uber kernel; got Δ=\(after - before)."
        )
    }

    /// A filter whose `fusionBody` is `.unsupported` — modelled here
    /// by a locally-defined test filter with a standalone kernel —
    /// continues to dispatch through the legacy
    /// `ComputeDispatcher.dispatch(kernel:)` path. No uber kernel is
    /// compiled on its behalf.
    func testUnsupportedFilterBypassesCodegenPath() throws {
        // Register a test-local kernel that the custom filter will
        // reference by name; it is not an SDK-shipped filter and its
        // `fusionBody` defaults to `.unsupported`.
        let testLibrary = try makeCustomTestLibrary(device: device.metalDevice)
        ShaderLibrary.shared.register(testLibrary)
        defer { ShaderLibrary.shared.unregisterAll() }

        let source = try makeSolidTexture(width: 16, height: 16, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(CustomUnsupportedFilter())]
        )

        let before = UberKernelCache.shared.cachedPipelineCount
        let output = try pipeline.outputSync()
        let after = UberKernelCache.shared.cachedPipelineCount

        XCTAssertEqual(
            after - before, 0,
            "An `.unsupported` filter must dispatch via the legacy standalone-kernel path and must not compile an uber kernel; got Δ=\(after - before)."
        )

        let px = try readFirstPixel(output)
        XCTAssertTrue(px.r.isFinite)
    }

    // MARK: - Phase 5 step 5.2 — PipelineOptimization knob

    /// `Pipeline.optimization` defaults to `.full`. Confirmed at the
    /// API level rather than by observable behaviour since `.full`
    /// vs `.none` produce identical graphs before cross-filter fusion
    /// lands in step 5.3.
    func testOptimizationDefaultsToFull() throws {
        let source = try makeSolidTexture(width: 4, height: 4, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(ExposureFilter(exposure: 5))]
        )
        XCTAssertEqual(pipeline.optimization, .full)
    }

    /// Fusion must preserve the per-pixel semantics of the chain.
    /// A three-filter chain under `.full` (collapsed to one cluster)
    /// and the same chain under `.none` (three independent
    /// dispatches feeding through rgba16Float intermediates) should
    /// produce bit-close output. The margin covers the Float16
    /// rounding that the independent-dispatch path incurs at each
    /// intermediate texture write, which the fused cluster avoids
    /// by keeping values in shader-local registers.
    func testFullAndNoneProduceBitCloseOutput() throws {
        let source = try makeSolidTexture(width: 8, height: 8, red: 0.4)
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 15)),
            .single(ContrastFilter(contrast: 20, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.1)),
        ]

        let fullOut = try makePipeline(
            input: .texture(source), steps: steps, optimization: .full
        ).outputSync()
        let noneOut = try makePipeline(
            input: .texture(source), steps: steps, optimization: .none
        ).outputSync()

        let fullPx = try readFirstPixel(fullOut)
        let nonePx = try readFirstPixel(noneOut)

        // Tolerance: 3 filters × Float16 round on the intermediate
        // write ≈ 0.003 channel, padded to 0.005 for safety.
        XCTAssertEqual(fullPx.r, nonePx.r, accuracy: 0.005)
        XCTAssertEqual(fullPx.g, nonePx.g, accuracy: 0.005)
        XCTAssertEqual(fullPx.b, nonePx.b, accuracy: 0.005)
    }

    /// A chain containing a multi-pass filter must fall back to the
    /// per-step loop because `MultiPassExecutor` owns the pass graph
    /// of `HighlightShadowFilter` / `ClarityFilter` / `SoftGlowFilter`
    /// / `PortraitBlurFilter`. The compiler path rejects graphs
    /// containing `.nativeCompute` nodes (emitted for each pass of a
    /// multi-pass filter) so the legacy dispatch handles the
    /// multi-pass filter while the single-pass filters adjacent to
    /// it still route through the codegen path — their step loop
    /// iterations individually invoke `ComputeBackend` via the
    /// `dispatchThroughComputeBackend` hook.
    func testMixedChainFallsBackToPerStepDispatch() throws {
        let source = try makeSolidTexture(width: 32, height: 32, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .multi(HighlightShadowFilter(highlights: 20)),
                .single(SaturationFilter(saturation: 1.1)),
            ]
        )

        let before = UberKernelCache.shared.cachedPipelineCount
        let output = try pipeline.outputSync()
        let after = UberKernelCache.shared.cachedPipelineCount

        // Exposure + Saturation each compile their own uber kernel
        // via the per-step codegen path (step 5.1). Two uber kernels
        // total; HighlightShadow dispatches its passes through
        // `MultiPassExecutor` with zero uber-kernel compilation.
        XCTAssertEqual(
            after - before, 2,
            "Mixed chain should compile one uber kernel per adjacent single-pass filter and leave the multi-pass filter on the legacy path; got Δ=\(after - before)."
        )

        let px = try readFirstPixel(output)
        XCTAssertTrue(px.r.isFinite && px.g.isFinite && px.b.isFinite)
    }

    /// LUT3D is a pixel-local filter but its signature shape is
    /// `.pixelLocalWithLUT3D`, not `.pixelLocalOnly`. VerticalFusion
    /// only merges members of matching signature shape (Phase 3
    /// step 3c lock), so a chain `[Exposure, LUT3D, Saturation]`
    /// stays as three independent nodes — not one cluster — under
    /// `.full`. All three land in the compiler path (eligible
    /// kinds), just as separate dispatches.
    func testLUT3DBreaksVerticalFusion() throws {
        // Minimal identity 2³ LUT cube payload.
        let identity2Cube: [Float] = [
            0, 0, 0, 1,  1, 0, 0, 1,
            0, 1, 0, 1,  1, 1, 0, 1,
            0, 0, 1, 1,  1, 0, 1, 1,
            0, 1, 1, 1,  1, 1, 1, 1,
        ]
        let cubeData = identity2Cube.withUnsafeBufferPointer { Data(buffer: $0) }

        let source = try makeSolidTexture(width: 16, height: 16, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(try LUT3DFilter(cubeData: cubeData, dimension: 2, intensity: 1.0)),
                .single(SaturationFilter(saturation: 1.1)),
            ],
            optimization: .full
        )

        let before = UberKernelCache.shared.cachedPipelineCount
        _ = try pipeline.outputSync()
        let after = UberKernelCache.shared.cachedPipelineCount

        XCTAssertEqual(
            after - before, 3,
            "LUT3D's distinct signature shape should stop VerticalFusion — expected three uber kernels in the chain, got Δ=\(after - before)."
        )
    }

    // MARK: - Fixtures

    private func makePipeline(
        input: PipelineInput,
        steps: [AnyFilter],
        optimization: PipelineOptimization = .full
    ) -> Pipeline {
        Pipeline(
            input: input,
            steps: steps,
            optimizer: FilterGraphOptimizer(),
            optimization: optimization,
            intermediatePixelFormat: .rgba16Float,
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

    private func readFirstPixel(
        _ texture: MTLTexture
    ) throws -> (r: Float, g: Float, b: Float, a: Float) {
        // Blit the private-storage output into a shared staging
        // texture so the CPU can read it.
        guard let staging = device.metalDevice.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width, height: texture.height,
                mipmapped: false
            )
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            return d
        }()) else {
            throw XCTSkip("Unable to allocate staging texture")
        }

        let queue = try XCTUnwrap(device.metalDevice.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeBlitCommandEncoder())
        enc.copy(
            from: texture,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: staging,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt16](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            staging.getBytes(
                raw.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0
            )
        }
        return (
            r: Float(Float16(bitPattern: bytes[0])),
            g: Float(Float16(bitPattern: bytes[1])),
            b: Float(Float16(bitPattern: bytes[2])),
            a: Float(Float16(bitPattern: bytes[3]))
        )
    }

    private func makeCustomTestLibrary(device: MTLDevice) throws -> MTLLibrary {
        // A trivial identity kernel that the test's
        // `CustomUnsupportedFilter` references. This kernel is
        // registered at test setup and cleared at teardown.
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void phase5_test_identity(
            texture2d<half, access::write> output [[texture(0)]],
            texture2d<half, access::read>  input  [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            output.write(input.read(gid), gid);
        }
        """
        return try device.makeLibrary(source: source, options: nil)
    }
}

// MARK: - Test filter with `.unsupported` fusionBody

/// A minimal `FilterProtocol` implementation whose `fusionBody`
/// defaults to `.unsupported` (the default-implementation path on
/// `FilterProtocol`). Used by
/// `testUnsupportedFilterBypassesCodegenPath` to confirm that the
/// Phase-5 step-5.1 routing leaves non-fusion filters on the legacy
/// `ComputeDispatcher` path.
@available(iOS 18.0, *)
private struct CustomUnsupportedFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "phase5_test_identity") }
    // `fusionBody` intentionally omitted — the default
    // `.unsupported` applies.
}
