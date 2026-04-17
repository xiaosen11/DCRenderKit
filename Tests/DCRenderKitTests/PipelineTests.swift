//
//  PipelineTests.swift
//  DCRenderKitTests
//
//  End-to-end tests for the top-level Pipeline. Covers single-pass and
//  multi-pass filters mixed in a chain, async/await semantics, identity
//  behavior, and error propagation.
//

import XCTest
@testable import DCRenderKit
import Metal

final class PipelineTests: XCTestCase {

    var device: Device!
    var psoCache: PipelineStateCache!
    var uniformPool: UniformBufferPool!
    var samplerCache: SamplerCache!
    var texturePool: TexturePool!
    var commandBufferPool: CommandBufferPool!
    var textureLoader: TextureLoader!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 3, bufferSize: 256)
        samplerCache = SamplerCache(device: d)
        texturePool = TexturePool(device: d, maxBytes: 32 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)

        ShaderLibrary.shared.unregisterAll()
        ShaderLibrary.shared.register(try makePipelineTestLibrary(device: d.metalDevice))
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        commandBufferPool = nil
        texturePool = nil
        samplerCache = nil
        uniformPool = nil
        psoCache = nil
        textureLoader = nil
        device = nil
        super.tearDown()
    }

    private func makePipeline(
        input: PipelineInput,
        steps: [AnyFilter]
    ) -> Pipeline {
        Pipeline(
            input: input,
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
    }

    // MARK: - Empty chain

    func testEmptyChainReturnsSource() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0.7)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: []
        )
        let output = try pipeline.outputSync()
        XCTAssertTrue(output === source)
    }

    // MARK: - Single single-pass filter

    func testSingleFilterChain() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0.3)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(SimpleScaleFilter(factor: 2.0))]
        )
        let output = try pipeline.outputSync()

        let pixels = try readPixels(output)
        XCTAssertEqual(pixels[4][4].r, 0.6, accuracy: 0.02)
    }

    // MARK: - Multiple single-pass filters chained

    func testMultipleSinglePassFilters() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0.25)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(SimpleScaleFilter(factor: 2.0)),    // 0.25 → 0.5
                .single(SimpleScaleFilter(factor: 1.5)),    // 0.5 → 0.75
            ]
        )
        let output = try pipeline.outputSync()

        let pixels = try readPixels(output)
        XCTAssertEqual(pixels[4][4].r, 0.75, accuracy: 0.02)
    }

    // MARK: - Multi-pass filter

    func testMultiPassFilterInChain() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0.4)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(SimpleScaleFilter(factor: 2.0)),   // 0.4 → 0.8
                .multi(SimpleTwoPassFilter()),              // identity via two passes
            ]
        )
        let output = try pipeline.outputSync()

        let pixels = try readPixels(output)
        XCTAssertEqual(pixels[4][4].r, 0.8, accuracy: 0.02)
    }

    // MARK: - Mixed single + multi filters

    func testMixedFilterChain() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0.1)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(SimpleScaleFilter(factor: 2.0)),   // 0.1 → 0.2
                .multi(SimpleTwoPassFilter()),              // identity
                .single(SimpleScaleFilter(factor: 3.0)),   // 0.2 → 0.6
            ]
        )
        let output = try pipeline.outputSync()

        let pixels = try readPixels(output)
        XCTAssertEqual(pixels[4][4].r, 0.6, accuracy: 0.02)
    }

    // MARK: - Async API

    func testAsyncOutputReturnsTexture() async throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0.5)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(SimpleScaleFilter(factor: 1.0))]   // identity
        )
        let output = try await pipeline.output()
        XCTAssertEqual(output.width, 8)
        let pixels = try readPixels(output)
        XCTAssertEqual(pixels[4][4].r, 0.5, accuracy: 0.02)
    }

    // MARK: - Error propagation

    func testMissingKernelPropagates() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(NonexistentKernelFilter())]
        )
        do {
            _ = try pipeline.outputSync()
            XCTFail("Expected throw")
        } catch PipelineError.pipelineState(.functionNotFound) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRenderModifierInSinglePassThrows() throws {
        let source = try makePipelineTexture(width: 8, height: 8, red: 0)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [.single(RenderModifierFilter())]
        )
        do {
            _ = try pipeline.outputSync()
            XCTFail("Expected throw")
        } catch PipelineError.filter(.invalidPassGraph) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - FilterGraphOptimizer passthrough

    func testOptimizerPassthroughBehavior() {
        let optimizer = FilterGraphOptimizer()
        let steps: [AnyFilter] = [
            .single(SimpleScaleFilter(factor: 1.0)),
            .single(SimpleScaleFilter(factor: 2.0)),
        ]
        let result = optimizer.optimize(steps)
        XCTAssertEqual(result.count, 2)
    }

    func testOptimizerDisabledReturnsInput() {
        var optimizer = FilterGraphOptimizer()
        optimizer.isEnabled = false
        let steps: [AnyFilter] = [
            .single(SimpleScaleFilter(factor: 1.0))
        ]
        let result = optimizer.optimize(steps)
        XCTAssertEqual(result.count, 1)
    }
}

// MARK: - Test filters

private struct SimpleScaleFilter: FilterProtocol {
    var factor: Float

    struct Uniforms { var factor: Float }

    var modifier: ModifierEnum { .compute(kernel: "pipeline_scale") }
    var uniforms: FilterUniforms {
        FilterUniforms(Uniforms(factor: factor))
    }
    static var fuseGroup: FuseGroup? { nil }
}

private struct NonexistentKernelFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "does_not_exist") }
}

private struct RenderModifierFilter: FilterProtocol {
    var modifier: ModifierEnum {
        .render(vertex: "vs", fragment: "fs")
    }
}

private struct SimpleTwoPassFilter: MultiPassFilter {
    func passes(input: TextureInfo) -> [Pass] {
        [
            Pass.compute(
                name: "a",
                kernel: "pipeline_identity",
                inputs: [.source],
                output: .sameAsSource
            ),
            Pass.final(
                kernel: "pipeline_identity",
                inputs: [.named("a")]
            ),
        ]
    }
}

// MARK: - Test library

private func makePipelineTestLibrary(device: MTLDevice) throws -> MTLLibrary {
    let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void pipeline_identity(
        texture2d<half, access::write> output [[texture(0)]],
        texture2d<half, access::read>  input  [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        output.write(input.read(gid), gid);
    }

    struct ScaleU { float factor; };

    kernel void pipeline_scale(
        texture2d<half, access::write> output [[texture(0)]],
        texture2d<half, access::read>  input  [[texture(1)]],
        constant ScaleU& u                    [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        half4 c = input.read(gid);
        c.rgb = clamp(c.rgb * half(u.factor), half3(0.0h), half3(1.0h));
        output.write(c, gid);
    }
    """
    return try device.makeLibrary(source: source, options: nil)
}

// MARK: - Helpers

private struct Px {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makePipelineTexture(
    width: Int, height: Int,
    red: Float, green: Float = 0, blue: Float = 0, alpha: Float = 1
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let hr = Float16(red).bitPattern
    let hg = Float16(green).bitPattern
    let hb = Float16(blue).bitPattern
    let ha = Float16(alpha).bitPattern
    for i in 0..<(width * height) {
        pixels[i * 4 + 0] = hr
        pixels[i * 4 + 1] = hg
        pixels[i * 4 + 2] = hb
        pixels[i * 4 + 3] = ha
    }
    pixels.withUnsafeBytes { bytes in
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: width * 8
        )
    }
    return tex
}

private func readPixels(_ texture: MTLTexture) throws -> [[Px]] {
    // Private-storage textures (produced by the pool) can't be read from
    // the CPU directly. Copy into a shared-storage staging texture first
    // via a blit.
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }

    let width = texture.width
    let height = texture.height
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: texture.pixelFormat,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let staging = try XCTUnwrap(device.makeTexture(descriptor: desc))

    let commandBuffer = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    try BlitDispatcher.copy(source: texture, destination: staging, commandBuffer: commandBuffer)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    var raw = [UInt16](repeating: 0, count: width * height * 4)
    raw.withUnsafeMutableBytes { bytes in
        staging.getBytes(
            bytes.baseAddress!,
            bytesPerRow: width * 8,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    var result: [[Px]] = []
    for y in 0..<height {
        var row: [Px] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(Px(
                r: Float(Float16(bitPattern: raw[offset + 0])),
                g: Float(Float16(bitPattern: raw[offset + 1])),
                b: Float(Float16(bitPattern: raw[offset + 2])),
                a: Float(Float16(bitPattern: raw[offset + 3]))
            ))
        }
        result.append(row)
    }
    return result
}
