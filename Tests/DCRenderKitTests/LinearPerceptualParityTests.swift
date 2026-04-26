//
//  LinearPerceptualParityTests.swift
//  DCRenderKitTests
//
//  Comprehensive parity sweep: every tone-space filter must produce
//  the same visual output in `.linear` and `.perceptual` modes (after
//  re-gamma-encoding the linear output). This is the formal
//  replacement for findings-and-plan §7.3's "feel drift" tech-debt
//  description — drift is now a numerical quantity with a pass/fail
//  threshold rather than a subjective impression.
//
//  Covered filters (all Session C Tier 1.3 principled replacements +
//  Session B grade-stabilized filters):
//
//    - ContrastFilter  (DaVinci log-slope)
//    - BlacksFilter    (Reinhard toe)
//    - WhitesFilter    (Filmic shoulder)
//    - ExposureFilter  (Reinhard positive, linear-gain negative)
//    - WhiteBalanceFilter (YIQ + Kelvin piecewise)
//
//  Out of scope:
//
//    - FilterProtocol filters that have no linear/perceptual branch
//      (Saturation, Vibrance — both operate in OKLCh regardless of
//      the pipeline's numeric space; color-space choice only
//      determines texture decode).
//    - SharpenFilter / FilmGrainFilter — no linear/perceptual
//      branch; math is space-agnostic.
//
//  Test design:
//
//    For each filter, sweep `slider × input_grey` through a dense
//    grid. At every grid point, run the filter twice:
//      (1) perceptual mode with gamma input  g = 0.1 ... 0.9
//      (2) linear mode    with linear input  l = sRGB_gamma⁻¹(g)
//
//    Re-gamma-encode the linear-mode output (`l_out → g(l_out)`);
//    it must equal the perceptual-mode output within tolerance.
//
//    Passing this means: running the filter in `.linear` produces the
//    same visual result as running in `.perceptual`, with no
//    perceptible feel drift. That is the strong form of the linear
//    mode's design contract (see DCRColorSpace doc).
//

import XCTest
@testable import DCRenderKit
import Metal

final class LinearPerceptualParityTests: XCTestCase {

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

    // MARK: - Tolerance budget

    // Every filter's parity test re-converts a Float16 intermediate
    // texture through a pow(_, 2.4) (IEC 61966-2-1) on each axis. That
    // builds up the following per-call error budget:
    //
    //   - Float16 quantization on input, intermediate, output:
    //     ~3 × 0.2 % = 0.6 %
    //   - IEC piecewise pow() precision on linearize + re-gamma:
    //     ~0.5 % at midtones (pow → Float16 round-trip)
    //   - GPU pow() / log / exp implementation precision:
    //     ~0.2 %
    //   - Filter-specific: Contrast has a pow(ratio, slope) that
    //     amplifies input noise by slope (up to 3× at slider 100)
    //
    // Total ≈ 1.5 % end-to-end, rounded up to **0.03** (3 %) for the
    // Contrast sweep (highest noise amplification). Other filters
    // tolerate 0.02 comfortably.
    private static let tightTolerance: Float = 0.02
    private static let contrastTolerance: Float = 0.03

    // MARK: - Sweep grid

    private static let sliderSweep: [Float] = [-100, -50, -25, 0, 25, 50, 100]
    private static let inputGammaSweep: [Float] = [
        0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9,
    ]

    // MARK: - Contrast

    func testContrastLinearPerceptualParitySweep() throws {
        // Contrast consumes a `lumaMean` in the pipeline's current
        // space (Swift-side API contract). Perceptual mode receives
        // a gamma-space mean; linear mode receives the linear
        // equivalent. Using a flat 0.5 in both modes would shift the
        // pivot between the two runs and inject a spurious drift.
        let gammaPivot: Float = 0.5
        let linearPivot = SRGBGammaSwiftMirror.gammaToLinear(gammaPivot)
        try runParitySweep(
            tolerance: Self.contrastTolerance,
            filterLabel: "Contrast",
            makeFilterPerceptual: { slider, _ in
                ContrastFilter(contrast: slider, lumaMean: gammaPivot, colorSpace: .perceptual)
            },
            makeFilterLinear: { slider, _ in
                ContrastFilter(contrast: slider, lumaMean: linearPivot, colorSpace: .linear)
            }
        )
    }

    // MARK: - Blacks

    func testBlacksLinearPerceptualParitySweep() throws {
        try runParitySweep(
            tolerance: Self.tightTolerance,
            filterLabel: "Blacks",
            makeFilterPerceptual: { slider, _ in
                BlacksFilter(blacks: slider, colorSpace: .perceptual)
            },
            makeFilterLinear: { slider, _ in
                BlacksFilter(blacks: slider, colorSpace: .linear)
            }
        )
    }

    // MARK: - Whites

    func testWhitesLinearPerceptualParitySweep() throws {
        try runParitySweep(
            tolerance: Self.tightTolerance,
            filterLabel: "Whites",
            makeFilterPerceptual: { slider, _ in
                WhitesFilter(whites: slider, colorSpace: .perceptual)
            },
            makeFilterLinear: { slider, _ in
                WhitesFilter(whites: slider, colorSpace: .linear)
            }
        )
    }

    // MARK: - Exposure
    //
    // Exposure's positive branch is Reinhard in linear; the perceptual
    // shader linearizes before Reinhard. Parity should be near-exact
    // after re-gamma (both branches feed Reinhard the same linear
    // value, differing only by Float16 intermediate precision).

    func testExposureLinearPerceptualParitySweep() throws {
        try runParitySweep(
            tolerance: Self.tightTolerance,
            filterLabel: "Exposure",
            makeFilterPerceptual: { slider, _ in
                ExposureFilter(exposure: slider, colorSpace: .perceptual)
            },
            makeFilterLinear: { slider, _ in
                ExposureFilter(exposure: slider, colorSpace: .linear)
            }
        )
    }

    // MARK: - WhiteBalance
    //
    // WhiteBalance has two axes (temperature, tint). We only sweep
    // temperature here — tint has its own parity proof elsewhere, and
    // joint sweep would explode the grid.

    func testWhiteBalanceLinearPerceptualParitySweep() throws {
        let temperatures: [Float] = [4000, 4500, 5000, 5500, 6500, 8000]
        for gammaInput in Self.inputGammaSweep {
            for tempK in temperatures {
                let linearInput = SRGBGammaSwiftMirror.gammaToLinear(gammaInput)

                let perceptualFilter = WhiteBalanceFilter(
                    temperature: tempK, tint: 0, colorSpace: .perceptual
                )
                let linearFilter = WhiteBalanceFilter(
                    temperature: tempK, tint: 0, colorSpace: .linear
                )

                let gammaOutput = try runFilter(
                    source: try makeGreySource(value: gammaInput),
                    filter: perceptualFilter
                )
                let linearOutput = try runFilter(
                    source: try makeGreySource(value: linearInput),
                    filter: linearFilter
                )

                let pG = try readRed(gammaOutput)
                let pL = try readRed(linearOutput)
                let pLAsGamma = SRGBGammaSwiftMirror.linearToGamma(pL)

                XCTAssertEqual(
                    pLAsGamma, pG, accuracy: Self.tightTolerance,
                    "WhiteBalance parity drift at (temp=\(tempK)K, gamma input=\(gammaInput)): linear→re-gamma=\(pLAsGamma) vs perceptual=\(pG)"
                )
            }
        }
    }

    // MARK: - Sweep driver

    /// Run `makeFilterPerceptual` on a gamma-encoded uniform grey
    /// patch; run `makeFilterLinear` on the linearized equivalent;
    /// re-gamma the linear output and compare pixelwise.
    ///
    /// The `_` in the filter factory signature is `lumaMean` — kept
    /// as a placeholder so Contrast (which needs it) and Blacks
    /// (which doesn't) can share the same driver.
    private func runParitySweep<F: FilterProtocol>(
        tolerance: Float,
        filterLabel: String,
        makeFilterPerceptual: (Float, Float) -> F,
        makeFilterLinear: (Float, Float) -> F
    ) throws {
        for slider in Self.sliderSweep {
            for gammaInput in Self.inputGammaSweep {
                let linearInput = SRGBGammaSwiftMirror.gammaToLinear(gammaInput)

                let perceptualOutput = try runFilter(
                    source: try makeGreySource(value: gammaInput),
                    filter: makeFilterPerceptual(slider, gammaInput)
                )
                let linearOutput = try runFilter(
                    source: try makeGreySource(value: linearInput),
                    filter: makeFilterLinear(slider, linearInput)
                )

                let pG = try readRed(perceptualOutput)
                let pL = try readRed(linearOutput)
                let pLAsGamma = SRGBGammaSwiftMirror.linearToGamma(pL)

                XCTAssertEqual(
                    pLAsGamma, pG, accuracy: tolerance,
                    "\(filterLabel) parity drift at slider=\(slider), gamma input=\(gammaInput): linear→re-gamma=\(pLAsGamma), perceptual=\(pG), |Δ|=\(abs(pLAsGamma - pG))"
                )
            }
        }
    }

    // MARK: - Helpers

    private func runFilter<F: FilterProtocol>(
        source: MTLTexture, filter: F
    ) throws -> MTLTexture {
        let pipeline = Pipeline(
            intermediatePixelFormat: .rgba16Float,
            device: device,
            textureLoader: textureLoader,
            psoCache: psoCache,
            uniformPool: uniformPool,
            samplerCache: samplerCache,
            texturePool: texturePool,
            commandBufferPool: commandBufferPool

        )
        return try pipeline.processSync(
            input: .texture(source),
            steps: [.single(filter)]
        )
    }

    private func makeGreySource(
        value: Float, width: Int = 4, height: Int = 4
    ) throws -> MTLTexture {
        guard let metalDevice = Device.tryShared?.metalDevice else {
            throw XCTSkip("Metal device required")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(metalDevice.makeTexture(descriptor: desc))
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let h = Float16(value).bitPattern
        let ha = Float16(1.0).bitPattern
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = h
            pixels[i * 4 + 1] = h
            pixels[i * 4 + 2] = h
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

    /// Sample the centre pixel's red channel (grey patches have R=G=B).
    private func readRed(_ texture: MTLTexture) throws -> Float {
        guard let metalDevice = Device.tryShared?.metalDevice else {
            throw XCTSkip("Metal device required")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width, height: texture.height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let staging = try XCTUnwrap(metalDevice.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(metalDevice.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try BlitDispatcher.copy(source: texture, destination: staging, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var raw = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes { bytes in
            staging.getBytes(
                bytes.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
        }
        let cx = texture.width / 2
        let cy = texture.height / 2
        let offset = (cy * texture.width + cx) * 4
        return Float(Float16(bitPattern: raw[offset]))
    }
}

// MARK: - IEC 61966-2-1 Swift mirror

/// Independent Swift implementation of the sRGB piecewise transfer
/// function. Used to compute the gamma ↔ linear conversions that the
/// parity sweep uses to build its input pairs and re-encode outputs.
/// Matches `Foundation/SRGBGamma.metal` byte-for-byte.
private enum SRGBGammaSwiftMirror {
    static func linearToGamma(_ c: Float) -> Float {
        let cc = max(c, 0)
        if cc <= 0.0031308 {
            return 12.92 * cc
        }
        return 1.055 * powf(cc, 1.0 / 2.4) - 0.055
    }

    static func gammaToLinear(_ c: Float) -> Float {
        let cc = max(c, 0)
        if cc <= 0.04045 {
            return cc / 12.92
        }
        return powf((cc + 0.055) / 1.055, 2.4)
    }
}
