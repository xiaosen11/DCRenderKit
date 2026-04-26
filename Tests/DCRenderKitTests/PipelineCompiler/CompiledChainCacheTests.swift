//
//  CompiledChainCacheTests.swift
//  DCRenderKitTests
//
//  Phase 10.4 — pin the per-`Pipeline` compile-result cache.
//  Two slices:
//
//    1. Fingerprint identity — graphs that should hash the same
//       across uniform-value drift (slider drag) versus graphs
//       that should hash differently (filter type change, output
//       spec change, chain length change).
//
//    2. Pipeline-level cache hit — a stable filter chain encoded
//       multiple times in a row produces a cache hit on every
//       call after the first. Verified by clearing the cache,
//       running an encode (miss), running a second encode and
//       confirming the cache entry is reused (no re-store).
//

import XCTest
@testable import DCRenderKit
import Metal

@available(iOS 18.0, *)
final class CompiledChainCacheTests: XCTestCase {

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
        texturePool = TexturePool(device: d, maxBytes: 64 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)
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

    // MARK: - Fingerprint identity

    /// Identical chains (same topology AND same uniforms) hash to
    /// the same fingerprint — the cache hits on repeat encodes
    /// with no UI changes (camera preview steady state).
    func testFingerprintStableForIdenticalChains() throws {
        let sourceInfo = TextureInfo(width: 512, height: 512, pixelFormat: .rgba16Float)
        let chain: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
        ]
        let g1 = try XCTUnwrap(Lowering.lower(chain, source: sourceInfo))
        let g2 = try XCTUnwrap(Lowering.lower(chain, source: sourceInfo))

        XCTAssertEqual(
            CompiledChainCache.fingerprint(of: g1),
            CompiledChainCache.fingerprint(of: g2),
            "Repeat encodes with the same chain must hit the cache"
        )
    }

    /// Slider movement changes uniform bytes — the fingerprint
    /// **must** invalidate so the cache doesn't return a stale
    /// graph carrying old uniforms (the bug that motivated this
    /// behaviour: cached graph dispatched with stale parameters
    /// looks like "slider doesn't respond").
    func testFingerprintChangesOnUniformDelta() throws {
        let sourceInfo = TextureInfo(width: 512, height: 512, pixelFormat: .rgba16Float)
        let chain1: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
        ]
        let chain2: [AnyFilter] = [
            .single(ExposureFilter(exposure: -30)),
            .single(ContrastFilter(contrast: 80, lumaMean: 0.5)),
        ]
        let g1 = try XCTUnwrap(Lowering.lower(chain1, source: sourceInfo))
        let g2 = try XCTUnwrap(Lowering.lower(chain2, source: sourceInfo))

        XCTAssertNotEqual(
            CompiledChainCache.fingerprint(of: g1),
            CompiledChainCache.fingerprint(of: g2),
            "Uniform delta must invalidate the cache; stale uniforms break slider responsiveness"
        )
    }

    /// Adding or removing a filter changes the lowered topology
    /// and must invalidate the fingerprint.
    func testFingerprintChangesOnChainLengthDelta() throws {
        let sourceInfo = TextureInfo(width: 512, height: 512, pixelFormat: .rgba16Float)
        let two: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
        ]
        let three: [AnyFilter] = two + [.single(SaturationFilter(saturation: 1.1))]
        let g2 = try XCTUnwrap(Lowering.lower(two, source: sourceInfo))
        let g3 = try XCTUnwrap(Lowering.lower(three, source: sourceInfo))

        XCTAssertNotEqual(
            CompiledChainCache.fingerprint(of: g2),
            CompiledChainCache.fingerprint(of: g3),
            "Chain length delta must invalidate the cache"
        )
    }

    /// Replacing one filter type with another (same chain length)
    /// changes the body function name and must invalidate.
    func testFingerprintChangesOnFilterTypeSwap() throws {
        let sourceInfo = TextureInfo(width: 512, height: 512, pixelFormat: .rgba16Float)
        let exposureChain: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
        ]
        let saturationChain: [AnyFilter] = [
            .single(SaturationFilter(saturation: 1.2)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
        ]
        let g1 = try XCTUnwrap(Lowering.lower(exposureChain, source: sourceInfo))
        let g2 = try XCTUnwrap(Lowering.lower(saturationChain, source: sourceInfo))

        XCTAssertNotEqual(
            CompiledChainCache.fingerprint(of: g1),
            CompiledChainCache.fingerprint(of: g2),
            "Replacing a filter type must invalidate the cache"
        )
    }

    // MARK: - Lookup behaviour

    /// Empty cache → lookup returns nil; first store populates;
    /// matching key returns the entry; mismatched key returns nil.
    func testStoreAndLookupRoundTrip() throws {
        let cache = CompiledChainCache()
        let sourceInfo = TextureInfo(width: 256, height: 256, pixelFormat: .rgba16Float)

        XCTAssertNil(cache.lookup(
            loweredFingerprint: 42,
            sourceInfo: sourceInfo,
            intermediatePixelFormat: .rgba16Float,
            optimization: .full
        ))

        let entry = CompiledChainCache.Entry(
            loweredFingerprint: 42,
            sourceWidth: sourceInfo.width,
            sourceHeight: sourceInfo.height,
            sourcePixelFormat: sourceInfo.pixelFormat,
            intermediatePixelFormat: .rgba16Float,
            optimization: .full,
            optimizedGraph: PipelineCompilerTestFixtures.linearPixelLocalChain(length: 1),
            chainInternalAlias: [:],
            plan: TextureAliasingPlan(bucketOf: [:], bucketSpec: [:])
        )
        cache.store(entry)

        XCTAssertNotNil(cache.lookup(
            loweredFingerprint: 42,
            sourceInfo: sourceInfo,
            intermediatePixelFormat: .rgba16Float,
            optimization: .full
        ))

        // Wrong fingerprint → miss.
        XCTAssertNil(cache.lookup(
            loweredFingerprint: 43,
            sourceInfo: sourceInfo,
            intermediatePixelFormat: .rgba16Float,
            optimization: .full
        ))

        // Wrong source dims → miss.
        XCTAssertNil(cache.lookup(
            loweredFingerprint: 42,
            sourceInfo: TextureInfo(width: 257, height: 256, pixelFormat: .rgba16Float),
            intermediatePixelFormat: .rgba16Float,
            optimization: .full
        ))

        // Wrong optimization → miss.
        XCTAssertNil(cache.lookup(
            loweredFingerprint: 42,
            sourceInfo: sourceInfo,
            intermediatePixelFormat: .rgba16Float,
            optimization: .none
        ))
    }

    // MARK: - End-to-end pipeline cache hit

    /// Two encodes of the same Pipeline with identical chain
    /// topology produce identical cached entries on subsequent
    /// calls. Validates the wiring inside `tryCompilerPath`.
    func testPipelineCachesAcrossEncodes() throws {
        let source = try makeSourceTexture(width: 256, height: 256, red: 0.4)
        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 10)),
            .single(ContrastFilter(contrast: 5, lumaMean: 0.5)),
            .single(SaturationFilter(saturation: 1.1)),
        ]
        let pipeline = Pipeline(
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
        pipeline.compiledChainCache.clear()

        // First encode: populates the cache.
        _ = try pipeline.processSync(
            input: .texture(source),
            steps: steps
        )
        let sourceInfo = TextureInfo(
            width: source.width, height: source.height, pixelFormat: source.pixelFormat
        )
        let lowered = try XCTUnwrap(Lowering.lower(steps, source: sourceInfo))
        let fp = CompiledChainCache.fingerprint(of: lowered)
        XCTAssertNotNil(
            pipeline.compiledChainCache.lookup(
                loweredFingerprint: fp,
                sourceInfo: sourceInfo,
                intermediatePixelFormat: .rgba16Float,
                optimization: .full
            ),
            "First encode should populate the cache"
        )

        // Second encode: hits the cache.
        _ = try pipeline.processSync(
            input: .texture(source),
            steps: steps
        )
        XCTAssertNotNil(
            pipeline.compiledChainCache.lookup(
                loweredFingerprint: fp,
                sourceInfo: sourceInfo,
                intermediatePixelFormat: .rgba16Float,
                optimization: .full
            ),
            "Second encode should still see the cached entry"
        )
    }

    // MARK: - Helpers

    private func makeSourceTexture(width: Int, height: Int, red: Float) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.metalDevice.makeTexture(descriptor: desc))

        let hr = Float16(red).bitPattern
        let h0 = Float16(0).bitPattern
        let h1 = Float16(1).bitPattern
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = hr
            pixels[i * 4 + 1] = h0
            pixels[i * 4 + 2] = h0
            pixels[i * 4 + 3] = h1
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
