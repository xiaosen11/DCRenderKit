//
//  FilmGrainPatternTests.swift
//  DCRenderKitTests
//
//  §8.1 A.3: verify FilmGrain's sin-trick hash does not exhibit visible
//  banding at 4K. Runs `FilmGrainFilter` on a uniform 4096×4096 gray
//  patch and checks that row/column mean standard deviations are
//  consistent with uncorrelated noise (no periodic horizontal or
//  vertical structure).
//
//  Why sin-trick is a risk at 4K:
//  `fract(sin(dot(pos, float2(12.9898, 78.233)) + lumaOffset) · 43758.5453)`
//  is a well-known shadertoy hash but relies on `sin` of large arguments
//  for decorrelation. At large `pos` (4096+), floating-point precision
//  of `sin` degrades, which historically has produced visible diagonal
//  banding / cross patterns in GPU implementations.
//

import XCTest
@testable import DCRenderKit
import Metal

final class FilmGrainPatternTests: XCTestCase {

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
        // 4K rgba16Float = 128 MB per texture; pipeline needs input + output
        // + possibly one intermediate = up to ~400 MB. Bump pool beyond
        // the default 32 MB used by other Effects tests.
        // 4K rgba16Float = 128 MB per texture; pipeline input + output =
        // ~260 MB. Pool budget 512 MB covers this with margin for staging.
        texturePool = TexturePool(device: d, maxBytes: 512 * 1024 * 1024)
        commandBufferPool = CommandBufferPool(device: d, maxInFlight: 4)
        textureLoader = TextureLoader(device: d)
        ShaderLibrary.shared.unregisterAll()
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

    // MARK: - 4K pattern banding check

    /// Run FilmGrain on a uniform 4K gray patch and verify the sin-trick
    /// hash produces noise that is statistically uncorrelated across rows
    /// and columns.
    ///
    /// Detection mechanism — 1D row/column mean stddev:
    /// - Compute per-row mean of R channel → `rowMeans[y]` (length 4096)
    /// - Compute per-column mean of R channel → `colMeans[x]` (length 4096)
    /// - If pixel noise is i.i.d., per-row-mean stddev should be
    ///   `σ_pixel / √N` where N = 4096 (central limit theorem).
    /// - If the hash exhibits horizontal banding, certain rows will
    ///   disproportionately cluster above or below 0.5 → per-row-mean
    ///   stddev inflates beyond the i.i.d. baseline.
    ///
    /// Baseline derivation:
    /// - Grain amplitude after SoftLight clamp is `0.144 · density` on each
    ///   channel. At `density = 1.0`, the delta injected into each pixel is
    ///   approximately `0.144 · u` where `u` is the shaped noise in `[-1, 1]`.
    /// - With `roughness = 0.5` the shaping exponent is 1.25 — the resulting
    ///   distribution has stddev ≈ 0.5 (empirical, close to uniform).
    /// - So per-pixel delta stddev σ ≈ 0.144 · 0.5 ≈ 0.072.
    /// - SoftLight gradient at mid-gray (base = 0.5) is
    ///   `d(result)/d(blend) = 2 · base · (1 - base) = 0.5`, so the output
    ///   delta stddev ≈ σ · 0.5 ≈ 0.036.
    /// - Per-row-mean baseline = 0.036 / √4096 ≈ 0.00056.
    ///
    /// Flag threshold: 5× baseline ≈ 0.0028. Deliberately generous so a
    /// clean hash comfortably passes; real banding (e.g., a sinusoidal
    /// pattern repeating every few hundred rows) would push row-mean
    /// stddev into the 0.01+ range.
    ///
    /// If this test fails, the `FilmGrainFilter.metal` sin-trick needs
    /// replacement with PCG hash or Wyvill hash (see §8.1 A.3 plan).
    func test4KFilmGrainSinTrickRowColumnBanding() throws {
        // Full 4K per §8.1 A.3 spec (4096×4096 uniform gray patch).
        let dim = 4096
        let source = try makeUniformGrayTexture(dim: dim, value: 0.5)

        let output = try runSingle(
            source,
            filter: FilmGrainFilter(
                density: 1.0,
                roughness: 0.5,
                chromaticity: 0,
                grainSize: 1
            )
        )

        let rChannel = try readRChannel(output)

        // Row and column means on the R channel.
        var rowMeans = [Double](repeating: 0, count: dim)
        var colSums = [Double](repeating: 0, count: dim)
        for y in 0..<dim {
            var rowSum: Double = 0
            let base = y * dim
            for x in 0..<dim {
                let v = Double(rChannel[base + x])
                rowSum += v
                colSums[x] += v
            }
            rowMeans[y] = rowSum / Double(dim)
        }
        let colMeans = colSums.map { $0 / Double(dim) }

        let rowStddev = standardDeviation(rowMeans)
        let colStddev = standardDeviation(colMeans)

        // Independent-noise baseline per derivation above.
        let baseline = 0.036 / sqrt(Double(dim))  // ≈ 0.00056
        let flagThreshold = 5.0 * baseline        // ≈ 0.0028

        // Print for manual inspection in CI logs and local runs.
        print("[FilmGrain 4K sin-trick] " +
              "rowStddev=\(rowStddev) colStddev=\(colStddev) " +
              "baseline=\(baseline) threshold=\(flagThreshold)")

        XCTAssertLessThan(
            rowStddev, flagThreshold,
            "Row means show periodic structure; likely horizontal banding " +
            "in sin-trick hash. Consider PCG/Wyvill hash per §8.1 A.3."
        )
        XCTAssertLessThan(
            colStddev, flagThreshold,
            "Column means show periodic structure; likely vertical banding " +
            "in sin-trick hash. Consider PCG/Wyvill hash per §8.1 A.3."
        )

        // Sanity: the filter actually added noise (else the test is moot).
        let rChannelDoubles = rChannel.map { Double($0) }
        let pixelStddev = standardDeviation(rChannelDoubles)
        XCTAssertGreaterThan(
            pixelStddev, 0.01,
            "FilmGrain at density=1 must produce visible noise — " +
            "if 0, the filter itself is broken before we can measure banding"
        )
    }

    // MARK: - Helpers

    private func makeUniformGrayTexture(
        dim: Int,
        value: Float
    ) throws -> MTLTexture {
        let mtlDevice = try XCTUnwrap(Device.tryShared?.metalDevice)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: dim, height: dim, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(mtlDevice.makeTexture(descriptor: desc))

        var pixels = [UInt16](repeating: 0, count: dim * dim * 4)
        let hv = Float16(value).bitPattern
        let ha = Float16(1.0).bitPattern
        for i in 0..<(dim * dim) {
            pixels[i * 4 + 0] = hv
            pixels[i * 4 + 1] = hv
            pixels[i * 4 + 2] = hv
            pixels[i * 4 + 3] = ha
        }
        pixels.withUnsafeBytes { bytes in
            tex.replace(
                region: MTLRegionMake2D(0, 0, dim, dim),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: dim * 8
            )
        }
        return tex
    }

    private func readRChannel(_ texture: MTLTexture) throws -> [Float] {
        // Pipeline output textures come from TexturePool with private
        // storage mode; direct getBytes would SIGSEGV. Blit into a
        // shared-storage staging texture first (same pattern as
        // EffectsFilterTests.readEffectTexture).
        let mtlDevice = try XCTUnwrap(Device.tryShared?.metalDevice)
        let dim = texture.width
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: dim, height: dim, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let staging = try XCTUnwrap(mtlDevice.makeTexture(descriptor: desc))

        let commandBuffer = try XCTUnwrap(
            mtlDevice.makeCommandQueue()?.makeCommandBuffer()
        )
        try BlitDispatcher.copy(
            source: texture,
            destination: staging,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var raw = [UInt16](repeating: 0, count: dim * dim * 4)
        raw.withUnsafeMutableBytes { bytes in
            staging.getBytes(
                bytes.baseAddress!,
                bytesPerRow: dim * 8,
                from: MTLRegionMake2D(0, 0, dim, dim),
                mipmapLevel: 0
            )
        }
        var result = [Float](repeating: 0, count: dim * dim)
        for i in 0..<(dim * dim) {
            result[i] = Float(Float16(bitPattern: raw[i * 4 + 0]))
        }
        return result
    }

    private func runSingle<F: FilterProtocol>(
        _ source: MTLTexture,
        filter: F
    ) throws -> MTLTexture {
        let pipeline = Pipeline(
            input: .texture(source),
            steps: [.single(filter)],
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
        return try pipeline.outputSync()
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { acc, v in
            let delta = v - mean
            return acc + delta * delta
        } / Double(values.count - 1)
        return sqrt(variance)
    }
}
