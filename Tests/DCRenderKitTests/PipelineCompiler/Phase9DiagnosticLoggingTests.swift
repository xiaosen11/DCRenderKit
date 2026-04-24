//
//  Phase9DiagnosticLoggingTests.swift
//  DCRenderKitTests
//
//  Phase 9 instrumentation smoke: verifies the compiler-path hot
//  path emits structured log messages under the `PipelineCompiler` /
//  `PipelineMem` / `PipelineBackend` categories when
//  ``DCRLogging/diagnosticPipelineLogging`` is enabled, and emits
//  nothing when disabled. Uses an injected `DCRLogger` that captures
//  events into an array rather than routing them to `os.Logger`.
//

import XCTest
import Metal
@testable import DCRenderKit

@available(iOS 18.0, *)
final class Phase9DiagnosticLoggingTests: XCTestCase {

    private var device: Device!
    private var psoCache: PipelineStateCache!
    private var uniformPool: UniformBufferPool!
    private var samplerCache: SamplerCache!
    private var texturePool: TexturePool!
    private var commandBufferPool: CommandBufferPool!
    private var textureLoader: TextureLoader!

    private var savedLogger: DCRLogger!
    private var savedLoggingFlag: Bool!

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

        savedLogger = DCRLogging.logger
        savedLoggingFlag = DCRLogging.diagnosticPipelineLogging
        UberKernelCache.shared.clear()
    }

    override func tearDown() {
        DCRLogging.logger = savedLogger
        DCRLogging.diagnosticPipelineLogging = savedLoggingFlag
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

    /// With the flag off, the compiler path runs silently — no
    /// `PipelineCompiler` / `PipelineMem` / `PipelineBackend`
    /// messages reach the logger. This is the default for Release
    /// builds.
    func testLoggingSilentWhenFlagDisabled() throws {
        let capture = CapturingLogger()
        DCRLogging.logger = capture
        DCRLogging.diagnosticPipelineLogging = false

        let source = try makeSolidTexture(width: 16, height: 16)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
            ]
        )
        _ = try pipeline.outputSync()

        let pipelineMsgs = capture.events.filter {
            $0.category == "PipelineCompiler"
                || $0.category == "PipelineMem"
                || $0.category == "PipelineBackend"
        }
        XCTAssertTrue(
            pipelineMsgs.isEmpty,
            "Diagnostic logging must be off when the flag is false; captured \(pipelineMsgs.count) unwanted messages."
        )
    }

    /// With the flag on, the compiler path emits at minimum a
    /// `PipelineCompiler` "compiler path taken" line, a
    /// `PipelineMem` "allocator plan" line, and one
    /// `PipelineBackend` "uber kernel dispatch" line per dispatched
    /// node.
    func testLoggingPopulatesExpectedCategoriesWhenFlagEnabled() throws {
        let capture = CapturingLogger()
        DCRLogging.logger = capture
        DCRLogging.diagnosticPipelineLogging = true

        let source = try makeSolidTexture(width: 16, height: 16)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
                .single(SaturationFilter(saturation: 1.1)),
            ]
        )
        _ = try pipeline.outputSync()

        let compiler = capture.events.filter { $0.category == "PipelineCompiler" }
        XCTAssertTrue(
            compiler.contains(where: { $0.message.contains("compiler path taken") }),
            "Expected a PipelineCompiler \"compiler path taken\" event; got: \(compiler.map { $0.message })"
        )

        let mem = capture.events.filter { $0.category == "PipelineMem" }
        XCTAssertTrue(
            mem.contains(where: { $0.message.contains("allocator plan") }),
            "Expected a PipelineMem \"allocator plan\" event; got: \(mem.map { $0.message })"
        )

        let backend = capture.events.filter { $0.category == "PipelineBackend" }
        XCTAssertGreaterThanOrEqual(
            backend.count, 1,
            "Expected at least one PipelineBackend \"uber kernel dispatch\" event."
        )
        XCTAssertTrue(
            backend.allSatisfy { $0.message.contains("uber kernel dispatch") },
            "Every PipelineBackend event should be a dispatch log line."
        )
    }

    /// The allocator-plan log line carries the compression ratio
    /// attribute. For a chain the optimiser collapses into one
    /// cluster node, the ratio reads `1.00` (1 node → 1 bucket); for
    /// a multi-node graph the ratio > 1 indicates aliasing fired.
    func testAllocatorPlanLineCarriesCompressionRatio() throws {
        let capture = CapturingLogger()
        DCRLogging.logger = capture
        DCRLogging.diagnosticPipelineLogging = true

        let source = try makeSolidTexture(width: 16, height: 16)
        let pipeline = makePipeline(
            input: .texture(source),
            steps: [
                .single(ExposureFilter(exposure: 10)),
                .single(ContrastFilter(contrast: 10, lumaMean: 0.5)),
                .single(SaturationFilter(saturation: 1.1)),
            ]
        )
        _ = try pipeline.outputSync()

        let plan = capture.events.first {
            $0.category == "PipelineMem" && $0.message.contains("allocator plan")
        }
        let planEvent = try XCTUnwrap(plan)
        XCTAssertNotNil(
            planEvent.attributes["compressionRatio"],
            "allocator plan event must carry a compressionRatio attribute"
        )
        XCTAssertNotNil(
            planEvent.attributes["peakMB"],
            "allocator plan event must carry a peakMB attribute"
        )
    }

    // MARK: - Fixtures

    private func makePipeline(
        input: PipelineInput,
        steps: [AnyFilter]
    ) -> Pipeline {
        Pipeline(
            input: input,
            steps: steps,
            optimizer: FilterGraphOptimizer(),
            optimization: .full,
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
        red: Float = 0.5, green: Float = 0.5, blue: Float = 0.5, alpha: Float = 1.0
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
}

// MARK: - Capturing logger

/// DCRLogger implementation that records every log event into an
/// array. Used by Phase-9 tests to inspect what the compiler path
/// emits without routing through `os.Logger`.
@available(iOS 18.0, *)
private final class CapturingLogger: DCRLogger, @unchecked Sendable {

    struct Event {
        let level: DCRLogLevel
        let category: String
        let message: String
        let attributes: [String: String]
    }

    private let lock = NSLock()
    private var _events: [Event] = []

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func log(
        level: DCRLogLevel,
        category: String,
        message: String,
        attributes: [String: String],
        error: Error?,
        file: String,
        line: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        _events.append(Event(
            level: level,
            category: category,
            message: message,
            attributes: attributes
        ))
    }
}
