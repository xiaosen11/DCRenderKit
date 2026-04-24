//
//  ComputeBackendTests.swift
//  DCRenderKitTests
//
//  End-to-end smoke tests for the Phase-3 ComputeBackend: build
//  uber kernel → compile → dispatch → read-back. Confirms the
//  dispatch path actually executes on the GPU and that the
//  cache is effective (second call ⇒ zero compilation).
//
//  Pixel-exact parity against the legacy kernels lives in the
//  separate LegacyParityTests file (Phase 3 Step 5). These tests
//  cover the plumbing, not the numerics.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class ComputeBackendTests: XCTestCase {

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

    // MARK: - Single-node identity dispatch

    /// `ExposureFilter(exposure: 0)` at identity must leave every
    /// pixel unchanged (up to Float16 quantisation). This is the
    /// smallest possible proof that codegen → compile → dispatch
    /// flows end-to-end correctly.
    func testExposureIdentityDispatchPreservesInput() throws {
        let node = try singleNode(for: ExposureFilter(exposure: 0))
        let input = makeRamp256x1()
        let output = try allocateOutput(like: input)

        let commandBuffer = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: node,
            source: input,
            destination: output,
            commandBuffer: commandBuffer,
            uberCache: UberKernelCache(device: .shared)    // isolated cache per test
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Float16 margin: two 16-bit rounding hops (read + write).
        let inputPixels = readBGRA8(input)
        let outputPixels = readBGRA8(output)
        XCTAssertEqual(inputPixels.count, outputPixels.count)
        for i in 0..<inputPixels.count {
            // BGRA8 channels round-trip within ±1 LSB of the original.
            XCTAssertLessThanOrEqual(
                abs(Int(inputPixels[i]) - Int(outputPixels[i])), 1,
                "Channel \(i) drifted beyond Float16 rounding"
            )
        }
    }

    /// `ExposureFilter(exposure: 50)` must produce brighter output
    /// on a linear-ramp input. Doesn't pin exact values (parity
    /// tests handle that) — just the direction, confirming the
    /// uniforms wire through.
    func testExposurePositiveDispatchBrightensMidGrayInput() throws {
        let node = try singleNode(for: ExposureFilter(exposure: 50))
        let input = makeUniformBGRA8(byte: 128)   // 50% mid-gray
        let output = try allocateOutput(like: input)

        let commandBuffer = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: node,
            source: input,
            destination: output,
            commandBuffer: commandBuffer,
            uberCache: UberKernelCache(device: .shared)
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let pixels = readBGRA8(output)
        // Any channel (b, g, r) of the first pixel — all should
        // be equal on uniform input.
        let channel = pixels[0]
        XCTAssertGreaterThan(
            channel, 128,
            "Positive exposure on mid-gray must produce a brighter channel value; got \(channel)"
        )
    }

    // MARK: - Cluster dispatch

    /// A 2-filter cluster (Exposure + Contrast) dispatches through
    /// a single uber kernel with two uniform buffer slots. Output
    /// at identity sliders (exposure=0, contrast=0) must match
    /// input within Float16 margin — same smoke-test rationale as
    /// the single-node identity path.
    func testClusterIdentityDispatchPreservesInput() throws {
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 0)),
            .single(ContrastFilter(contrast: 0, lumaMean: 0.5)),
        ]
        let lowered = try XCTUnwrap(Lowering.lower(
            steps,
            source: TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        ))
        let optimised = Optimizer.optimize(lowered)
        XCTAssertEqual(optimised.nodes.count, 1, "Two pixelLocals fuse into one cluster")
        let clusterNode = optimised.nodes[0]

        let input = makeRamp256x1()
        let output = try allocateOutput(like: input)

        let commandBuffer = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: clusterNode,
            source: input,
            destination: output,
            commandBuffer: commandBuffer,
            uberCache: UberKernelCache(device: .shared)
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let inputPixels = readBGRA8(input)
        let outputPixels = readBGRA8(output)
        for i in 0..<inputPixels.count {
            XCTAssertLessThanOrEqual(
                abs(Int(inputPixels[i]) - Int(outputPixels[i])), 1,
                "Channel \(i) drifted beyond Float16 rounding in cluster path"
            )
        }
    }

    // MARK: - Caching

    /// Second dispatch of the same node structure hits the cache —
    /// no new library or PSO is compiled. Verified by inspecting
    /// `cachedPipelineCount` after each dispatch.
    func testSecondDispatchHitsCache() throws {
        let node = try singleNode(for: ExposureFilter(exposure: 10))
        let input = makeRamp256x1()
        let output = try allocateOutput(like: input)

        let isolatedCache = UberKernelCache(device: .shared)
        XCTAssertEqual(isolatedCache.cachedPipelineCount, 0)

        let cb1 = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: node, source: input, destination: output,
            commandBuffer: cb1, uberCache: isolatedCache
        )
        cb1.commit()
        cb1.waitUntilCompleted()
        XCTAssertEqual(isolatedCache.cachedPipelineCount, 1,
                       "First dispatch populates the cache")

        // Second dispatch with a new node (but same hashed name —
        // different slider value) must reuse the PSO.
        let node2 = try singleNode(for: ExposureFilter(exposure: 80))
        let cb2 = queue.makeCommandBuffer()!
        try ComputeBackend.execute(
            node: node2, source: input, destination: output,
            commandBuffer: cb2, uberCache: isolatedCache
        )
        cb2.commit()
        cb2.waitUntilCompleted()
        XCTAssertEqual(isolatedCache.cachedPipelineCount, 1,
                       "Different slider value must share the cached PSO")
    }

    // MARK: - Test helpers

    private func singleNode(for filter: any FilterProtocol) throws -> Node {
        let lowered = try XCTUnwrap(Lowering.lower(
            [.single(filter)],
            source: TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)
        ))
        XCTAssertEqual(lowered.nodes.count, 1)
        return lowered.nodes[0]
    }

    /// 256×1 horizontal BGRA ramp: byte value equals x coordinate
    /// in every channel. Useful for identity tests because every
    /// possible 8-bit value is covered.
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
            bytes[x * 4 + 0] = UInt8(x)   // B
            bytes[x * 4 + 1] = UInt8(x)   // G
            bytes[x * 4 + 2] = UInt8(x)   // R
            bytes[x * 4 + 3] = 255        // A
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

    /// 1×1 BGRA texture whose b/g/r are all `byte` and a=255.
    private func makeUniformBGRA8(byte: UInt8) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1, height: 1,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        let tex = device.makeTexture(descriptor: desc)!
        var pixel: [UInt8] = [byte, byte, byte, 255]
        pixel.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: 4
            )
        }
        return tex
    }

    /// Allocate an output texture matching the input's dimensions
    /// in bgra8Unorm with shaderWrite usage.
    private func allocateOutput(like other: MTLTexture) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: other.width, height: other.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw XCTSkip("Unable to allocate output texture")
        }
        return tex
    }

    /// Read back a bgra8Unorm texture into a flat `[UInt8]` of
    /// length `width * height * 4`.
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
