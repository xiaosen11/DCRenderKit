//
//  ComputeDispatcherTests.swift
//  DCRenderKitTests
//
//  End-to-end tests for ComputeDispatcher using small inline Metal kernels.
//  Verifies binding convention (textures 0/1/2+, buffer 0), uniform marshaling,
//  and error paths.
//

import XCTest
@testable import DCRenderKit
import Metal

// All tests in this file need a real Metal device.

final class ComputeDispatcherTests: XCTestCase {

    var device: Device!
    var psoCache: PipelineStateCache!
    var uniformPool: UniformBufferPool!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 3, bufferSize: 256)
        ShaderLibrary.shared.unregisterAll()
        ShaderLibrary.shared.register(try makeTestLibrary(device: d.metalDevice))
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        psoCache = nil
        uniformPool = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Identity

    func testIdentityKernel() throws {
        let source = try makeTestTexture(width: 8, height: 8, fillRed: 1.0)
        let dest = try makeWritableTexture(width: 8, height: 8)

        let buffer = try device.makeCommandBuffer()
        try ComputeDispatcher.dispatch(
            kernel: "identity_kernel",
            source: source,
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        // Destination should now match source.
        let destPixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(destPixels[0][0].r, 1.0, accuracy: 0.01)
        XCTAssertEqual(destPixels[0][0].a, 1.0, accuracy: 0.01)
    }

    // MARK: - Uniforms

    func testUniformsAreBoundCorrectly() throws {
        let source = try makeTestTexture(width: 8, height: 8, fillRed: 0.5)
        let dest = try makeWritableTexture(width: 8, height: 8)

        struct ScaleUniforms {
            var factor: Float = 2.0
        }

        let buffer = try device.makeCommandBuffer()
        try ComputeDispatcher.dispatch(
            kernel: "scale_kernel",
            uniforms: FilterUniforms(ScaleUniforms()),
            source: source,
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        let destPixels = try readRGBA16Float(texture: dest)
        // Expected: red 0.5 × 2.0 = 1.0 (clamped).
        XCTAssertEqual(destPixels[0][0].r, 1.0, accuracy: 0.02)
    }

    // MARK: - Additional inputs

    func testAdditionalInputsBoundFromIndex2() throws {
        let source = try makeTestTexture(width: 8, height: 8, fillRed: 0.2)
        let overlay = try makeTestTexture(width: 8, height: 8, fillRed: 0.3)
        let dest = try makeWritableTexture(width: 8, height: 8)

        let buffer = try device.makeCommandBuffer()
        try ComputeDispatcher.dispatch(
            kernel: "add_two_kernel",
            additionalInputs: [overlay],
            source: source,
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        let destPixels = try readRGBA16Float(texture: dest)
        XCTAssertEqual(destPixels[0][0].r, 0.5, accuracy: 0.02)
    }

    // MARK: - Error paths

    func testMissingKernelThrows() throws {
        let source = try makeTestTexture(width: 8, height: 8, fillRed: 0.0)
        let dest = try makeWritableTexture(width: 8, height: 8)
        let buffer = try device.makeCommandBuffer()

        do {
            try ComputeDispatcher.dispatch(
                kernel: "__does_not_exist__",
                source: source,
                destination: dest,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool
            )
            XCTFail("Expected throw")
        } catch PipelineError.pipelineState(.functionNotFound) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testDestinationWithoutShaderWriteThrows() throws {
        let source = try makeTestTexture(width: 8, height: 8, fillRed: 0.0)
        // Create a destination without shaderWrite usage.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 8, height: 8, mipmapped: false
        )
        desc.usage = .shaderRead  // Not writable!
        let dest = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let buffer = try device.makeCommandBuffer()
        do {
            try ComputeDispatcher.dispatch(
                kernel: "identity_kernel",
                source: source,
                destination: dest,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool
            )
            XCTFail("Expected throw")
        } catch PipelineError.texture(.formatMismatch) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Asymmetric dimensions

    func testAsymmetricDestinationDoesNotThrow() throws {
        // Downsampling kernel writes half-resolution output from full input.
        let source = try makeTestTexture(width: 8, height: 8, fillRed: 0.5)
        let dest = try makeWritableTexture(width: 4, height: 4)

        let buffer = try device.makeCommandBuffer()
        // Use identity kernel which just copies; with smaller dest it'll only
        // cover the top-left 4×4 of source. This test just verifies no throw.
        try ComputeDispatcher.dispatch(
            kernel: "identity_kernel",
            source: source,
            destination: dest,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        XCTAssertNil(buffer.error)
    }
}

// MARK: - Test helpers

private struct RGBA16F {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

/// Build a Metal library with the minimal kernels used by these tests.
private func makeTestLibrary(device: MTLDevice) throws -> MTLLibrary {
    let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void identity_kernel(
        texture2d<half, access::write> output [[texture(0)]],
        texture2d<half, access::read>  input  [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        output.write(input.read(gid), gid);
    }

    struct ScaleUniforms { float factor; };

    kernel void scale_kernel(
        texture2d<half, access::write> output [[texture(0)]],
        texture2d<half, access::read>  input  [[texture(1)]],
        constant ScaleUniforms& u             [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        half4 c = input.read(gid);
        c.rgb = clamp(c.rgb * half(u.factor), half3(0.0h), half3(1.0h));
        output.write(c, gid);
    }

    kernel void add_two_kernel(
        texture2d<half, access::write> output  [[texture(0)]],
        texture2d<half, access::read>  inputA  [[texture(1)]],
        texture2d<half, access::read>  inputB  [[texture(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        half4 a = inputA.read(gid);
        half4 b = inputB.read(gid);
        output.write(a + b, gid);
    }
    """
    return try device.makeLibrary(source: source, options: nil)
}

/// Create a rgba16Float texture pre-filled with a uniform red value.
private func makeTestTexture(
    width: Int,
    height: Int,
    fillRed: Float,
    fillAlpha: Float = 1.0
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width,
        height: height,
        mipmapped: false
    )
    desc.usage = [.shaderRead]
    desc.storageMode = .shared

    let texture = try XCTUnwrap(device.makeTexture(descriptor: desc))

    // Fill with test pattern: half-precision values.
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let halfRed = Float16(fillRed).bitPattern
    let halfAlpha = Float16(fillAlpha).bitPattern
    for i in 0..<(width * height) {
        pixels[i * 4 + 0] = halfRed
        pixels[i * 4 + 1] = 0
        pixels[i * 4 + 2] = 0
        pixels[i * 4 + 3] = halfAlpha
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

private func makeWritableTexture(width: Int, height: Int) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    return try XCTUnwrap(device.makeTexture(descriptor: desc))
}

/// Read back a rgba16Float texture into a 2D array of `RGBA16F`.
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
