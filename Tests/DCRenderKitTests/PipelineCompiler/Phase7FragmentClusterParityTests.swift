//
//  Phase7FragmentClusterParityTests.swift
//  DCRenderKitTests
//
//  Phase 7 gate: confirm `RenderBackend.execute(...)` produces
//  bit-close output to `ComputeBackend.execute(...)` for the same
//  fused-pixel-local cluster on the same input. The compute path
//  is already parity-locked against the frozen legacy kernels in
//  `LegacyParityTests`, so a fragment-vs-compute match here means
//  the fragment path inherits the same per-pixel correctness without
//  needing its own legacy reference.
//
//  Tolerance: ±1 LSB in BGRA8 — Float16 rounding floor for a single
//  read→math→write round trip, which both the compute kernel and
//  the fragment shader incur identically.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class Phase7FragmentClusterParityTests: XCTestCase {

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    override func setUpWithError() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        guard let q = dev.makeCommandQueue() else {
            throw XCTSkip("Metal command queue unavailable")
        }
        device = dev
        queue = q
    }

    // MARK: - Tests

    /// The flagship 3-filter pure-tone chain `[Exposure, Contrast,
    /// Blacks]` (all `wantsLinearInput=false`, all `pixelLocalOnly`)
    /// fuses into one cluster. Both compute and fragment paths
    /// emit the same body chain; their per-pixel outputs must agree
    /// at ±1 LSB.
    func testThreeFilterClusterFragmentMatchesCompute() throws {
        try runParity(filters: [
            ExposureFilter(exposure: 30),
            ContrastFilter(contrast: 20, lumaMean: 0.5),
            BlacksFilter(blacks: 15),
        ])
    }

    /// `Saturation + Vibrance` cluster (both `wantsLinearInput=true`,
    /// both `pixelLocalOnly`). Exercises the OKLab helper injection
    /// path for the fragment build.
    func testSaturationVibranceClusterFragmentMatchesCompute() throws {
        try runParity(filters: [
            SaturationFilter(saturation: 1.3),
            VibranceFilter(vibrance: 0.4),
        ])
    }

    /// Single-member clusters (degenerate but legal) still produce
    /// a fragment shader; this case proves the codegen handles
    /// `members.count == 1` symmetrically with the multi-member case.
    func testSingleFilterClusterFragmentMatchesCompute() throws {
        try runParity(filters: [
            ExposureFilter(exposure: 25),
        ])
    }

    // MARK: - Parity runner

    private func runParity(
        filters: [any FilterProtocol],
        tolerance: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // Lower the chain — the cluster construction is verified
        // separately by Phase-2 tests; here we just need *some*
        // FusedClusterMembers to feed into both backends.
        let lowered = try XCTUnwrap(Lowering.lower(
            filters.map { .single($0) },
            source: TextureInfo(width: 256, height: 1, pixelFormat: .rgba16Float)
        ))
        let optimized = Optimizer.optimize(lowered)

        // Find the cluster node (or single pixel-local for the
        // 1-filter case — promote it to a single-member cluster).
        let clusterNode = try findOrSynthesizeCluster(
            optimized: optimized,
            filters: filters
        )

        let input = makeRamp256x1()
        let computeOut = try allocateOutput(width: input.width, height: input.height,
                                            usage: [.shaderRead, .shaderWrite])
        let renderOut = try allocateOutput(width: input.width, height: input.height,
                                           usage: [.shaderRead, .renderTarget])

        // Isolated caches so the test's compile counts don't bleed
        // into the shared cache.
        let computeCache = UberKernelCache(device: .shared)
        let renderCache = UberRenderPipelineCache(device: .shared)

        let cbCompute = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: clusterNode,
            source: input,
            destination: computeOut,
            additionalInputs: [],
            commandBuffer: cbCompute,
            uberCache: computeCache
        )
        cbCompute.commit()
        cbCompute.waitUntilCompleted()

        let cbRender = queue.makeCommandBuffer()!
        try RenderBackend.execute(
            node: clusterNode,
            source: input,
            destination: renderOut,
            commandBuffer: cbRender,
            renderCache: renderCache
        )
        cbRender.commit()
        cbRender.waitUntilCompleted()

        let computeBytes = readBGRA8(computeOut)
        let renderBytes = readBGRA8(renderOut)
        XCTAssertEqual(
            computeBytes.count, renderBytes.count,
            "Compute / render outputs differ in byte count",
            file: file, line: line
        )

        var worstDelta = 0
        var worstIndex = -1
        for i in 0..<computeBytes.count {
            let d = abs(Int(computeBytes[i]) - Int(renderBytes[i]))
            if d > worstDelta {
                worstDelta = d
                worstIndex = i
            }
        }
        XCTAssertLessThanOrEqual(
            worstDelta, tolerance,
            "Fragment cluster drifts ±\(worstDelta) LSB from compute at byte index \(worstIndex)",
            file: file, line: line
        )
    }

    // MARK: - Helpers

    /// Pull the optimised graph's cluster node, or — for a chain of
    /// length 1 — synthesise a single-member cluster from the lone
    /// pixel-local node so both backends operate on the same shape.
    private func findOrSynthesizeCluster(
        optimized: PipelineGraph,
        filters: [any FilterProtocol]
    ) throws -> Node {
        if let cluster = optimized.nodes.first(where: {
            if case .fusedPixelLocalCluster = $0.kind { return true }
            return false
        }) {
            return cluster
        }
        guard
            optimized.nodes.count == 1,
            case let .pixelLocal(body, uniforms, wantsLinear, _) = optimized.nodes[0].kind
        else {
            XCTFail("Expected a cluster or single pixelLocal node; got \(optimized.dump)")
            throw XCTSkip("graph shape mismatch")
        }
        let member = FusedClusterMember(
            body: body,
            uniforms: uniforms,
            debugLabel: optimized.nodes[0].debugLabel,
            additionalRange: 0..<0
        )
        return Node(
            id: optimized.nodes[0].id,
            kind: .fusedPixelLocalCluster(
                members: [member],
                wantsLinearInput: wantsLinear,
                additionalNodeInputs: []
            ),
            inputs: optimized.nodes[0].inputs,
            outputSpec: .sameAsSource,
            isFinal: true,
            debugLabel: "SingletonCluster"
        )
    }

    private func makeRamp256x1() -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 256, height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        let tex = device.makeTexture(descriptor: desc)!
        var bytes = [UInt8](repeating: 0, count: 256 * 4)
        for x in 0..<256 {
            bytes[x * 4 + 0] = UInt8(x)
            bytes[x * 4 + 1] = UInt8((x + 85) % 256)
            bytes[x * 4 + 2] = UInt8((x + 170) % 256)
            bytes[x * 4 + 3] = 255
        }
        bytes.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, 256, 1),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: 256 * 4
            )
        }
        return tex
    }

    private func allocateOutput(
        width: Int,
        height: Int,
        usage: MTLTextureUsage
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = usage
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Unable to allocate output texture")
        }
        return tex
    }

    private func readBGRA8(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        return bytes
    }
}
