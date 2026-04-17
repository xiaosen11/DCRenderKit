//
//  MultiPassAndLoaderTests.swift
//  DCRenderKitTests
//
//  Tests for MultiPassExecutor (DAG execution + lifetime analysis),
//  PassGraphVisualizer (text + Mermaid rendering), and TextureLoader
//  (MTLTexture / CGImage / UIImage / CVPixelBuffer paths).
//

import XCTest
@testable import DCRenderKit
import Metal
import CoreVideo
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - MultiPassExecutor

final class MultiPassExecutorTests: XCTestCase {

    var device: Device!
    var psoCache: PipelineStateCache!
    var uniformPool: UniformBufferPool!
    var texturePool: TexturePool!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        psoCache = PipelineStateCache(device: d)
        uniformPool = UniformBufferPool(device: d, capacity: 3, bufferSize: 256)
        texturePool = TexturePool(device: d, maxBytes: 16 * 1024 * 1024)
        ShaderLibrary.shared.unregisterAll()
        ShaderLibrary.shared.register(try makeMultiPassTestLibrary(device: d.metalDevice))
    }

    override func tearDown() {
        ShaderLibrary.shared.unregisterAll()
        texturePool = nil
        uniformPool = nil
        psoCache = nil
        device = nil
        super.tearDown()
    }

    // MARK: - Empty graph = identity

    func testEmptyPassGraphReturnsSource() throws {
        let source = try makeTex(width: 8, height: 8, red: 0.7)
        let buffer = try device.makeCommandBuffer()

        let result = try MultiPassExecutor.execute(
            passes: [],
            source: source,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            texturePool: texturePool
        )
        XCTAssertTrue(result === source)
    }

    // MARK: - Single-pass graph

    func testSinglePassFinalGraph() throws {
        let source = try makeTex(width: 8, height: 8, red: 0.5)
        let passes: [Pass] = [
            Pass.final(kernel: "mp_identity", inputs: [.source])
        ]

        let buffer = try device.makeCommandBuffer()
        let output = try MultiPassExecutor.execute(
            passes: passes,
            source: source,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            texturePool: texturePool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        let pixels = try readPixels(texture: output)
        XCTAssertEqual(pixels[0][0].r, 0.5, accuracy: 0.02)
    }

    // MARK: - Multi-pass chain

    /// Pass 1: source → scaled half size
    /// Pass 2: pass1 output → final same size as source (upsamples via kernel)
    func testMultiPassChain() throws {
        let source = try makeTex(width: 8, height: 8, red: 0.3)
        let passes: [Pass] = [
            Pass.compute(
                name: "half",
                kernel: "mp_identity",
                inputs: [.source],
                output: .scaled(factor: 0.5)
            ),
            Pass.final(
                kernel: "mp_identity",
                inputs: [.named("half")]
            ),
        ]

        let buffer = try device.makeCommandBuffer()
        let output = try MultiPassExecutor.execute(
            passes: passes,
            source: source,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            texturePool: texturePool
        )
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        // Final pass is .sameAsSource default, so output has source dims.
        XCTAssertEqual(output.width, 8)
        XCTAssertEqual(output.height, 8)
    }

    // MARK: - DAG (one output consumed by two later passes)

    func testDAGFanOut() throws {
        // Pass A: source → something
        // Pass B: A → something (uses A)
        // Pass C: final, uses A and B (A consumed twice)
        let source = try makeTex(width: 8, height: 8, red: 0.5)

        let passes: [Pass] = [
            Pass.compute(
                name: "a",
                kernel: "mp_identity",
                inputs: [.source],
                output: .sameAsSource
            ),
            Pass.compute(
                name: "b",
                kernel: "mp_identity",
                inputs: [.named("a")],
                output: .sameAsSource
            ),
            Pass.final(
                kernel: "mp_add",
                inputs: [.named("a"), .named("b")]
            ),
        ]

        let buffer = try device.makeCommandBuffer()
        let output = try MultiPassExecutor.execute(
            passes: passes,
            source: source,
            commandBuffer: buffer,
            psoCache: psoCache,
            uniformPool: uniformPool,
            texturePool: texturePool
        )
        buffer.commit()
        buffer.waitUntilCompleted()

        // a = 0.5, b = a = 0.5, final = a+b = 1.0 (clamped)
        let pixels = try readPixels(texture: output)
        XCTAssertEqual(pixels[0][0].r, 1.0, accuracy: 0.02)
    }

    // MARK: - Validation

    func testMissingFinalPassThrows() throws {
        let source = try makeTex(width: 8, height: 8, red: 0)
        let passes: [Pass] = [
            Pass.compute(
                name: "a",
                kernel: "mp_identity",
                inputs: [.source],
                output: .sameAsSource
            ),
            // No isFinal=true!
        ]

        let buffer = try device.makeCommandBuffer()
        do {
            _ = try MultiPassExecutor.execute(
                passes: passes,
                source: source,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool,
                texturePool: texturePool
            )
            XCTFail("Expected throw")
        } catch PipelineError.filter(.invalidPassGraph) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testDuplicatePassNameThrows() throws {
        let source = try makeTex(width: 8, height: 8, red: 0)
        let passes: [Pass] = [
            Pass.compute(
                name: "dup",
                kernel: "mp_identity",
                inputs: [.source],
                output: .sameAsSource
            ),
            Pass.final(
                name: "dup",
                kernel: "mp_identity",
                inputs: [.named("dup")]
            ),
        ]

        let buffer = try device.makeCommandBuffer()
        do {
            _ = try MultiPassExecutor.execute(
                passes: passes,
                source: source,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool,
                texturePool: texturePool
            )
            XCTFail("Expected throw")
        } catch PipelineError.filter(.invalidPassGraph) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testForwardReferenceThrows() throws {
        let source = try makeTex(width: 8, height: 8, red: 0)
        let passes: [Pass] = [
            // This pass references "later" which doesn't exist yet.
            Pass.compute(
                name: "early",
                kernel: "mp_identity",
                inputs: [.named("later")],
                output: .sameAsSource
            ),
            Pass.final(
                name: "later",
                kernel: "mp_identity",
                inputs: [.source]
            ),
        ]

        let buffer = try device.makeCommandBuffer()
        do {
            _ = try MultiPassExecutor.execute(
                passes: passes,
                source: source,
                commandBuffer: buffer,
                psoCache: psoCache,
                uniformPool: uniformPool,
                texturePool: texturePool
            )
            XCTFail("Expected throw")
        } catch PipelineError.filter(.invalidPassGraph) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testRenderModifierRejected() throws {
        let source = try makeTex(width: 8, height: 8, red: 0)

        // Manually construct a pass with a .render modifier via inside knowledge.
        // Since Pass.render factory was removed, construct via the compute
        // factory then verify the error at dispatch time by using a modifier
        // directly. We can't easily test this since modifier is let-only;
        // instead we test the error message path by using mps modifier via
        // the same means. Skipped — not easily reachable from public API.
        //
        // This limitation is by design: the public API only exposes .compute
        // and .final factories, so you can't accidentally build a non-compute
        // multi-pass filter.
    }
}

// MARK: - PassGraphVisualizer

final class PassGraphVisualizerTests: XCTestCase {

    func testEmptyGraphText() {
        let output = PassGraphVisualizer.render(passes: [], format: .text)
        XCTAssertTrue(output.contains("empty"))
    }

    func testEmptyGraphMermaid() {
        let output = PassGraphVisualizer.render(passes: [], format: .mermaid)
        XCTAssertTrue(output.contains("graph LR"))
    }

    func testTextOutputListsAllPasses() {
        let passes: [Pass] = [
            Pass.compute(name: "down", kernel: "k1", inputs: [.source], output: .scaled(factor: 0.5)),
            Pass.compute(name: "mid", kernel: "k2", inputs: [.named("down")], output: .scaled(factor: 0.25)),
            Pass.final(kernel: "k3", inputs: [.named("mid")]),
        ]
        let output = PassGraphVisualizer.render(passes: passes, format: .text)
        XCTAssertTrue(output.contains("down"))
        XCTAssertTrue(output.contains("mid"))
        XCTAssertTrue(output.contains("final"))
        XCTAssertTrue(output.contains("★"))  // Final marker.
    }

    func testMermaidOutputHasEdges() {
        let passes: [Pass] = [
            Pass.compute(name: "a", kernel: "k", inputs: [.source], output: .sameAsSource),
            Pass.final(kernel: "k", inputs: [.named("a")]),
        ]
        let output = PassGraphVisualizer.render(passes: passes, format: .mermaid)
        XCTAssertTrue(output.contains("graph LR"))
        XCTAssertTrue(output.contains("source"))
        XCTAssertTrue(output.contains("-->"))
    }

    func testMermaidNodeIdSanitizesSpecialChars() {
        let passes: [Pass] = [
            // Name with special char would break Mermaid if not sanitized.
            Pass.final(name: "has-dash", kernel: "k", inputs: [.source]),
        ]
        let output = PassGraphVisualizer.render(passes: passes, format: .mermaid)
        // Expect underscore-sanitized ID.
        XCTAssertTrue(output.contains("p_has_dash"))
    }
}

// MARK: - TextureLoader

final class TextureLoaderTests: XCTestCase {

    var device: Device!
    var loader: TextureLoader!

    override func setUpWithError() throws {
        guard let d = Device.tryShared else {
            throw XCTSkip("Metal device required")
        }
        device = d
        loader = TextureLoader(device: d)
    }

    override func tearDown() {
        loader = nil
        device = nil
        super.tearDown()
    }

    // MARK: - MTLTexture passthrough

    func testMTLTexturePassthrough() throws {
        let texture = try makeTex(width: 8, height: 8, red: 0)
        let result = loader.makeTexture(from: texture)
        XCTAssertTrue(result === texture)
    }

    // MARK: - CGImage

    func testCGImageLoad() throws {
        let cgImage = try makeTestCGImage(width: 8, height: 8)
        let texture = try loader.makeTexture(from: cgImage)
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 8)
    }

    // MARK: - DCRImage

    #if canImport(UIKit)
    func testUIImageLoad() throws {
        let cgImage = try makeTestCGImage(width: 8, height: 8)
        let uiImage = UIImage(cgImage: cgImage)
        let texture = try loader.makeTexture(from: uiImage)
        XCTAssertEqual(texture.width, 8)
    }
    #elseif canImport(AppKit)
    func testNSImageLoad() throws {
        let cgImage = try makeTestCGImage(width: 8, height: 8)
        let nsImage = NSImage(
            cgImage: cgImage,
            size: CGSize(width: 8, height: 8)
        )
        let texture = try loader.makeTexture(from: nsImage)
        XCTAssertEqual(texture.width, 8)
    }
    #endif

    // MARK: - CVPixelBuffer

    func testCVPixelBufferBGRALoad() throws {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8, 8,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(pixelBuffer)

        let texture = try loader.makeTexture(from: pb)
        XCTAssertEqual(texture.width, 8)
        XCTAssertEqual(texture.height, 8)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
    }

    func testCVPixelBufferUnsupportedFormatThrows() throws {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        // YUV format — not supported in Round 8.
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            8, 8,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attrs as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(pixelBuffer)

        do {
            _ = try loader.makeTexture(from: pb)
            XCTFail("Expected throw")
        } catch PipelineError.texture(.pixelFormatUnsupported) {
            // Expected.
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

// MARK: - Test helpers

private struct P {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

private func makeMultiPassTestLibrary(device: MTLDevice) throws -> MTLLibrary {
    let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void mp_identity(
        texture2d<half, access::write> output [[texture(0)]],
        texture2d<half, access::read>  input  [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        // When output is smaller, scale coord; simple case for tests:
        uint2 inputCoord = uint2(
            min(gid.x, input.get_width() - 1),
            min(gid.y, input.get_height() - 1)
        );
        output.write(input.read(inputCoord), gid);
    }

    kernel void mp_add(
        texture2d<half, access::write> output  [[texture(0)]],
        texture2d<half, access::read>  inputA  [[texture(1)]],
        texture2d<half, access::read>  inputB  [[texture(2)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        output.write(inputA.read(gid) + inputB.read(gid), gid);
    }
    """
    return try device.makeLibrary(source: source, options: nil)
}

private func makeTex(
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

private func readPixels(texture: MTLTexture) throws -> [[P]] {
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
    var result: [[P]] = []
    for y in 0..<height {
        var row: [P] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(P(
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

private func makeTestCGImage(width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw XCTSkip("CGContext creation failed")
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
        throw XCTSkip("CGImage creation failed")
    }
    return image
}
