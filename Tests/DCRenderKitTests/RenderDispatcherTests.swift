//
//  RenderDispatcherTests.swift
//  DCRenderKitTests
//
//  End-to-end tests using real vertex + fragment shaders. Verifies binding
//  convention, blend state, load actions, and batch draw semantics.
//

import XCTest
@testable import DCRenderKit
import Metal

final class RenderDispatcherTests: XCTestCase {

    var device: Device!
    var psoCache: PipelineStateCache!
    var uniformPool: UniformBufferPool!
    var samplerCache: SamplerCache!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 3, bufferSize: 256)
        samplerCache = SamplerCache(device: d)
        ShaderLibrary.shared.unregisterAll()
        ShaderLibrary.shared.register(try makeRenderTestLibrary(device: d.metalDevice))
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        psoCache = nil
        uniformPool = nil
        samplerCache = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Identity blit via render

    /// Draw a full-screen quad that samples the source texture and writes to
    /// destination. Equivalent to a texture copy but uses the full render
    /// pipeline including PSO cache and sampler binding.
    func testIdentityFullscreenQuad() throws {
        let source = try makeFilledTexture(
            width: 8, height: 8,
            red: 0.5, green: 0.3, blue: 0.1
        )
        let dest = try makeRenderableTexture(width: 8, height: 8)

        let descriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "sample_fragment",
            colorPixelFormat: .rgba16Float,
            blend: .opaque
        )

        let vertexBuffer = try makeFullscreenQuadBuffer()

        let buffer = try device.makeCommandBuffer()
        try RenderDispatcher.dispatch(
            descriptor: descriptor,
            vertexBuffer: vertexBuffer,
            vertexCount: 4,
            primitiveType: .triangleStrip,
            fragmentTextures: [source],
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        let pixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(pixels[4][4].r, 0.5, accuracy: 0.02)
        XCTAssertEqual(pixels[4][4].g, 0.3, accuracy: 0.02)
        XCTAssertEqual(pixels[4][4].b, 0.1, accuracy: 0.02)
    }

    // MARK: - PSO caching

    func testPSOIsCachedAcrossDispatches() throws {
        let source = try makeFilledTexture(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let dest = try makeRenderableTexture(width: 8, height: 8)
        let descriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "sample_fragment"
        )
        let vertexBuffer = try makeFullscreenQuadBuffer()

        XCTAssertEqual(psoCache.renderCacheCount, 0)

        for _ in 0..<3 {
            let buffer = try device.makeCommandBuffer()
            try RenderDispatcher.dispatch(
                descriptor: descriptor,
                vertexBuffer: vertexBuffer,
                vertexCount: 4,
                fragmentTextures: [source],
                destination: dest,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool,
                samplerCache: samplerCache
            )
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        // 3 dispatches with same descriptor = 1 cached PSO.
        XCTAssertEqual(psoCache.renderCacheCount, 1)
    }

    // MARK: - Blend state

    func testAlphaBlendOverlaysCorrectly() throws {
        // First pass: clear to red.
        // Second pass: draw half-alpha green overlay using .load + alphaBlend.
        // Expected result: mix of red and green.

        let source = try makeFilledTexture(
            width: 8, height: 8,
            red: 0, green: 1, blue: 0, alpha: 0.5
        )
        let dest = try makeRenderableTexture(width: 8, height: 8)

        // Pass 1: clear destination to red using .clear load action.
        let clearDescriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "solid_red_fragment",
            colorPixelFormat: .rgba16Float,
            blend: .opaque
        )

        let buffer1 = try device.makeCommandBuffer()
        try RenderDispatcher.dispatch(
            descriptor: clearDescriptor,
            vertexBuffer: try makeFullscreenQuadBuffer(),
            vertexCount: 4,
            destination: dest,
            loadAction: .clear,
            clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
            commandBuffer: buffer1,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache
        )
        buffer1.commit()
        buffer1.waitUntilCompleted()

        // Confirm red.
        var pixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(pixels[4][4].r, 1.0, accuracy: 0.02)

        // Pass 2: draw half-alpha green using .load + alphaBlend.
        // Source has (0, 1, 0, 0.5), so blended result at each pixel is
        //   dest' = source*source.a + dest*(1-source.a)
        //        = (0,1,0)*0.5 + (1,0,0)*0.5
        //        = (0.5, 0.5, 0)
        let blendDescriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "sample_fragment",
            colorPixelFormat: .rgba16Float,
            blend: .alphaBlend
        )

        let buffer2 = try device.makeCommandBuffer()
        try RenderDispatcher.dispatch(
            descriptor: blendDescriptor,
            vertexBuffer: try makeFullscreenQuadBuffer(),
            vertexCount: 4,
            fragmentTextures: [source],
            destination: dest,
            loadAction: .load,  // Preserve prior red.
            commandBuffer: buffer2,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache
        )
        buffer2.commit()
        buffer2.waitUntilCompleted()

        pixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(pixels[4][4].r, 0.5, accuracy: 0.03)
        XCTAssertEqual(pixels[4][4].g, 0.5, accuracy: 0.03)
        XCTAssertEqual(pixels[4][4].b, 0.0, accuracy: 0.02)
    }

    // MARK: - Uniforms

    func testVertexUniformsBindCorrectly() throws {
        // Vertex shader applies a horizontal offset from a vertex uniform.
        struct OffsetUniforms { var offsetX: Float = 0 }

        let source = try makeFilledTexture(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let dest = try makeRenderableTexture(width: 8, height: 8)

        let descriptor = RenderPSODescriptor(
            vertexFunction: "offset_vertex",
            fragmentFunction: "sample_fragment"
        )
        let vertexBuffer = try makeFullscreenQuadBuffer()

        let buffer = try device.makeCommandBuffer()
        try RenderDispatcher.dispatch(
            descriptor: descriptor,
            vertexBuffer: vertexBuffer,
            vertexCount: 4,
            vertexUniforms: FilterUniforms(OffsetUniforms(offsetX: 0.0)),
            fragmentTextures: [source],
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        // With offsetX = 0, no actual offset. Destination should match source.
        let pixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(pixels[4][4].r, 1.0, accuracy: 0.02)
    }

    // MARK: - Batched draws

    func testDispatchBatchRunsAllDraws() throws {
        // Two draw calls in one encoder — the second should execute and
        // overlay the first's output.
        let source1 = try makeFilledTexture(width: 8, height: 8, red: 1, green: 0, blue: 0)
        let source2 = try makeFilledTexture(
            width: 8, height: 8,
            red: 0, green: 1, blue: 0, alpha: 1.0
        )
        let dest = try makeRenderableTexture(width: 8, height: 8)

        let descriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "sample_fragment",
            blend: .opaque
        )
        let vertexBuffer = try makeFullscreenQuadBuffer()

        let buffer = try device.makeCommandBuffer()
        try RenderDispatcher.dispatchBatch(
            descriptor: descriptor,
            draws: [
                DrawCall(
                    vertexBuffer: vertexBuffer, vertexCount: 4,
                    fragmentTextures: [source1]
                ),
                DrawCall(
                    vertexBuffer: vertexBuffer, vertexCount: 4,
                    fragmentTextures: [source2]
                ),
            ],
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        // Second draw wins (opaque blend + .clear on first).
        let pixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(pixels[4][4].g, 1.0, accuracy: 0.02)
        XCTAssertEqual(pixels[4][4].r, 0.0, accuracy: 0.02)
    }

    // MARK: - Error paths

    func testDestinationWithoutRenderTargetThrows() throws {
        let source = try makeFilledTexture(width: 8, height: 8, red: 0, green: 0, blue: 0)
        // Dest without .renderTarget usage.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false
        )
        desc.usage = [.shaderRead]  // Missing .renderTarget.
        let dest = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let descriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "sample_fragment"
        )
        let vertexBuffer = try makeFullscreenQuadBuffer()

        let buffer = try device.makeCommandBuffer()
        do {
            try RenderDispatcher.dispatch(
                descriptor: descriptor,
                vertexBuffer: vertexBuffer,
                vertexCount: 4,
                fragmentTextures: [source],
                destination: dest,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool,
                samplerCache: samplerCache
            )
            XCTFail("Expected throw")
        } catch PipelineError.texture(.formatMismatch) {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testPixelFormatMismatchThrows() throws {
        // Dest is bgra8Unorm but descriptor specifies rgba16Float.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        let dest = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let source = try makeFilledTexture(width: 8, height: 8, red: 0, green: 0, blue: 0)
        let descriptor = RenderPSODescriptor(
            vertexFunction: "fullscreen_vertex",
            fragmentFunction: "sample_fragment",
            colorPixelFormat: .rgba16Float  // mismatch!
        )
        let vertexBuffer = try makeFullscreenQuadBuffer()

        let buffer = try device.makeCommandBuffer()
        do {
            try RenderDispatcher.dispatch(
                descriptor: descriptor,
                vertexBuffer: vertexBuffer,
                vertexCount: 4,
                fragmentTextures: [source],
                destination: dest,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool,
                samplerCache: samplerCache
            )
            XCTFail("Expected throw")
        } catch PipelineError.texture(.formatMismatch) {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

// MARK: - Helpers

private struct RGBA16F {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private struct QuadVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private func makeRenderTestLibrary(device: MTLDevice) throws -> MTLLibrary {
    let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 uv       [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen vertex: reads positions from vertex buffer at buffer(0).
    vertex VertexOut fullscreen_vertex(
        uint vid [[vertex_id]],
        constant float4* vertices [[buffer(0)]])
    {
        // vertices[vid] = (x, y, u, v)
        float4 vtx = vertices[vid];
        VertexOut out;
        out.position = float4(vtx.x, vtx.y, 0, 1);
        out.uv = float2(vtx.z, vtx.w);
        return out;
    }

    // Offset vertex: shifts each vertex horizontally by a uniform offset.
    struct OffsetUniforms { float offsetX; };

    vertex VertexOut offset_vertex(
        uint vid [[vertex_id]],
        constant float4* vertices              [[buffer(0)]],
        constant OffsetUniforms& u             [[buffer(1)]])
    {
        float4 vtx = vertices[vid];
        VertexOut out;
        out.position = float4(vtx.x + u.offsetX, vtx.y, 0, 1);
        out.uv = float2(vtx.z, vtx.w);
        return out;
    }

    // Fragment: sample a texture using the uv coords.
    fragment half4 sample_fragment(
        VertexOut in [[stage_in]],
        texture2d<half> tex [[texture(0)]],
        sampler samp [[sampler(0)]])
    {
        return tex.sample(samp, in.uv);
    }

    // Fragment: solid red (tests .clear + pass without textures).
    fragment half4 solid_red_fragment(
        VertexOut in [[stage_in]])
    {
        return half4(1, 0, 0, 1);
    }
    """
    return try device.makeLibrary(source: source, options: nil)
}

/// Build a fullscreen triangle strip with (x, y, u, v) packed as float4 per
/// vertex. Covers the full NDC region [-1, 1] × [-1, 1] and matches UV
/// [0, 1] × [0, 1].
///
/// Note: Metal texture Y axis points down in texture space but positions use
/// standard NDC (Y up). We flip V to match.
private func makeFullscreenQuadBuffer() throws -> MTLBuffer {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    var quad: [SIMD4<Float>] = [
        SIMD4<Float>(-1, -1, 0, 1),  // bottom-left
        SIMD4<Float>( 1, -1, 1, 1),  // bottom-right
        SIMD4<Float>(-1,  1, 0, 0),  // top-left
        SIMD4<Float>( 1,  1, 1, 0),  // top-right
    ]
    let byteCount = MemoryLayout<SIMD4<Float>>.stride * quad.count
    return try XCTUnwrap(device.makeBuffer(
        bytes: &quad,
        length: byteCount,
        options: .storageModeShared
    ))
}

private func makeFilledTexture(
    width: Int, height: Int,
    red: Float, green: Float, blue: Float, alpha: Float = 1
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))

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
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: width * 8
        )
    }
    return texture
}

private func makeRenderableTexture(width: Int, height: Int) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    return try XCTUnwrap(device.makeTexture(descriptor: desc))
}

private func readRGBA16Float(texture: MTLTexture) throws -> [[RGBA16F]] {
    let width = texture.width
    let height = texture.height
    var raw = [UInt16](repeating: 0, count: width * height * 4)
    raw.withUnsafeMutableBytes { bytes in
        texture.getBytes(
            bytes.baseAddress!,
            bytesPerRow: width * 8,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    var result: [[RGBA16F]] = []
    for y in 0..<height {
        var row: [RGBA16F] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(RGBA16F(
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
