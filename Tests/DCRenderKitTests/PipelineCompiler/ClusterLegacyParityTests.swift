//
//  ClusterLegacyParityTests.swift
//  DCRenderKitTests
//
//  Phase-3 step 6 — the cross-filter parity gate. Multi-filter
//  pixel-local chains must produce identical output when run
//  two ways:
//
//    1. Legacy path (serial): each filter dispatches its frozen
//       `DCRLegacy<Name>Filter` kernel in turn, ping-ponging
//       between two intermediate textures — the same semantic
//       the Phase-5 pipeline will retire.
//    2. Codegen path (fused): Lowering + Optimizer collapses the
//       chain into a single `.fusedPixelLocalCluster` node, and
//       `ComputeBackend.execute` dispatches one uber kernel.
//
//  Across both paths, every BGRA8 channel of the final output
//  must agree to within the same Float16-rounding-floor margin
//  the single-filter parity test uses. Cross-member precision
//  drift would surface here rather than in the single-filter
//  gate — this file is the tripwire for fusion correctness
//  specifically.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class ClusterLegacyParityTests: XCTestCase {

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
        do {
            try LegacyKernelFixture.registerIfNeeded()
        } catch LegacyKernelFixture.Error.metalDeviceUnavailable {
            throw XCTSkip("Metal device unavailable for legacy fixture")
        }
    }

    // MARK: - 2-filter cluster: tone + color

    /// Exposure + Contrast: two tone operators fuse into one
    /// cluster; its uber-kernel output must match the serial
    /// legacy pipeline.
    func testExposureContrastClusterParity() throws {
        try runClusterParity(
            filters: [
                ExposureFilter(exposure: 30),
                ContrastFilter(contrast: 20, lumaMean: 0.5),
            ],
            legacyKernelNames: [
                "DCRLegacyExposureFilter",
                "DCRLegacyContrastFilter",
            ]
        )
    }

    // MARK: - 3-filter cluster: the "feel" triad

    /// Exposure + Contrast + Saturation: the minimal realistic
    /// tone+color chain. This is the primary case where fusion
    /// earns its cost — three dispatches collapse to one.
    func testExposureContrastSaturationClusterParity() throws {
        try runClusterParity(
            filters: [
                ExposureFilter(exposure: 20),
                ContrastFilter(contrast: 15, lumaMean: 0.5),
                SaturationFilter(saturation: 1.25),
            ],
            legacyKernelNames: [
                "DCRLegacyExposureFilter",
                "DCRLegacyContrastFilter",
                "DCRLegacySaturationFilter",
            ]
        )
    }

    // MARK: - 5-filter cluster: heavy edit chain

    /// Exposure + Contrast + Blacks + Whites + WhiteBalance — a
    /// realistic heavy edit chain exercising the full tone
    /// family plus a colour-grading step. Five bodies in one
    /// uber kernel.
    func testFiveFilterClusterParity() throws {
        try runClusterParity(
            filters: [
                ExposureFilter(exposure: 15),
                ContrastFilter(contrast: 10, lumaMean: 0.5),
                BlacksFilter(blacks: 10),
                WhitesFilter(whites: -10),
                WhiteBalanceFilter(temperature: 6200, tint: 20),
            ],
            legacyKernelNames: [
                "DCRLegacyExposureFilter",
                "DCRLegacyContrastFilter",
                "DCRLegacyBlacksFilter",
                "DCRLegacyWhitesFilter",
                "DCRLegacyWhiteBalanceFilter",
            ],
            // Five Float16 round-trips accumulate: ±1 LSB at the
            // per-filter gate × 5 stages caps well under ±2 LSB
            // in BGRA8 for the legacy path, and fusion avoids the
            // intermediate round-trips so the codegen path is
            // tighter. Allow ±2 for the cross-path diff.
            tolerance: 2
        )
    }

    // MARK: - Runner

    /// Execute `filters` two ways and compare the final outputs
    /// pixel-by-pixel.
    ///
    /// Both paths write to BGRA8 textures (matching what a real
    /// display would see); `rgba16Float` intermediates between
    /// legacy stages are preserved as native `rgba16Float`
    /// textures to match production's default intermediate
    /// format. The cross-path comparison happens only on the
    /// final 8-bit output — any drift inside the chain has
    /// already been converted through the final filter's
    /// quantisation.
    private func runClusterParity(
        filters: [any FilterProtocol],
        legacyKernelNames: [String],
        tolerance: Int = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        precondition(
            filters.count == legacyKernelNames.count,
            "Kernel-name count must match filter count"
        )

        let input = makeRamp256x1BGRA()
        let legacyOut = try makeBGRA(width: input.width, height: input.height)
        let codegenOut = try makeBGRA(width: input.width, height: input.height)

        // 1. Serial legacy path. Allocate two ping-pong
        //    `rgba16Float` intermediates; route final output into
        //    `legacyOut` (bgra8Unorm).
        try runLegacyChain(
            filters: filters,
            legacyKernelNames: legacyKernelNames,
            source: input,
            finalDestination: legacyOut
        )

        // 2. Codegen path: lower → optimise → one uber dispatch.
        let isolatedCache = UberKernelCache(device: .shared)
        let steps: [AnyFilter] = filters.map { .single($0) }
        let lowered = try XCTUnwrap(Lowering.lower(
            steps,
            source: TextureInfo(
                width: input.width,
                height: input.height,
                pixelFormat: .rgba16Float
            )
        ))
        let optimised = Optimizer.optimize(lowered)
        XCTAssertEqual(
            optimised.nodes.count, 1,
            "All pixelLocalOnly filters should collapse into one cluster",
            file: file, line: line
        )
        let clusterNode = optimised.nodes[0]

        let cb = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: clusterNode,
            source: input,
            destination: codegenOut,
            commandBuffer: cb,
            uberCache: isolatedCache
        )
        cb.commit()
        cb.waitUntilCompleted()

        // 3. Compare.
        let legacyBytes = readBGRA8(legacyOut)
        let codegenBytes = readBGRA8(codegenOut)
        XCTAssertEqual(legacyBytes.count, codegenBytes.count,
                       "Output dimensions mismatch",
                       file: file, line: line)

        var worstDelta = 0
        var worstIndex = -1
        for i in 0..<legacyBytes.count {
            let d = abs(Int(legacyBytes[i]) - Int(codegenBytes[i]))
            if d > worstDelta {
                worstDelta = d
                worstIndex = i
            }
        }
        XCTAssertLessThanOrEqual(
            worstDelta, tolerance,
            "Cluster drifted ±\(worstDelta) LSB at index \(worstIndex) — expected ≤ \(tolerance)",
            file: file, line: line
        )
    }

    /// Dispatch every filter in `filters` through its legacy
    /// kernel in series, routing the final stage's output into
    /// `finalDestination` (bgra8Unorm). Intermediate stages use
    /// two ping-pong rgba16Float textures so the chain doesn't
    /// force 8-bit quantisation between filters.
    private func runLegacyChain(
        filters: [any FilterProtocol],
        legacyKernelNames: [String],
        source: MTLTexture,
        finalDestination: MTLTexture
    ) throws {
        let intermediateA = try makeFloat16(width: source.width, height: source.height)
        let intermediateB = try makeFloat16(width: source.width, height: source.height)

        var currentInput: MTLTexture = source
        let cb = queue.makeCommandBuffer()!
        for (index, filter) in filters.enumerated() {
            let isLast = (index == filters.count - 1)
            let dest: MTLTexture = isLast
                ? finalDestination
                : (index.isMultiple(of: 2) ? intermediateA : intermediateB)

            try ComputeDispatcher.dispatch(
                kernel: legacyKernelNames[index],
                uniforms: filter.uniforms,
                additionalInputs: filter.additionalInputs,
                source: currentInput,
                destination: dest,
                commandBuffer: cb
            )
            currentInput = dest
        }
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: - Texture helpers

    private func makeRamp256x1BGRA() -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 256, height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        let tex = device.makeTexture(descriptor: desc)!
        var bytes = [UInt8](repeating: 0, count: 256 * 4)
        for x in 0..<256 {
            bytes[x * 4 + 0] = UInt8(x)                  // B
            bytes[x * 4 + 1] = UInt8((x + 85) % 256)     // G
            bytes[x * 4 + 2] = UInt8((x + 170) % 256)    // R
            bytes[x * 4 + 3] = 255                       // A
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

    private func makeBGRA(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Unable to allocate BGRA8 texture")
        }
        return tex
    }

    private func makeFloat16(width: Int, height: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Unable to allocate rgba16Float texture")
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
