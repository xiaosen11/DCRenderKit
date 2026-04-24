//
//  PortraitBlurMaskPipelineTests.swift
//  DCRenderKitTests
//
//  Integration tests covering the end-to-end PortraitBlurMaskGenerator →
//  PortraitBlurFilter path exercised by DigiCam: a caller-supplied subject
//  mask flows through `PassInput.additional(0)` into both Poisson-disc
//  passes of the multi-pass blur filter. Kept at the SDK layer (no Demo
//  XCTest target) per the Session C decision in `docs/session-handoff.md`
//  §3.X ("Demo→SDK integration test").
//
//  ## What these tests prove beyond PortraitBlurAndStatisticsTests
//
//  That file already covers the extreme mask values (all-subject /
//  all-background) and the nil-mask identity path. This file adds three
//  integration-level guarantees that those unit tests do not establish:
//
//    1. Spatial selectivity across a mixed mask — proves the mask is
//       correctly routed to AND consumed by BOTH Poisson passes. If either
//       pass ignored `additional(0)` and treated mask as zero, the
//       subject half would get a second round of blur and leak toward the
//       source-ramp mean; the tight tolerance on the subject half catches
//       that regression.
//    2. A realistic DigiCam-style edit chain still routes the mask
//       correctly when PortraitBlur sits between tone / color filters —
//       catches regressions where upstream filter outputs feed into
//       PortraitBlur and the `additionalInputs` list must remain
//       associated with the filter struct, not the source texture.
//    3. Non-matching mask / source resolutions go through the shader's
//       coordinate remap path (`gid / inputW * maskW`) without coordinate
//       drift — catches regressions in the mask-sampling loop if the
//       shader is ever rewritten.
//
//  All synthetic sources and masks; no Vision / real photograph required.
//  Complements `SmokeTests`'s mask-driven chain tests with a narrow focus
//  on the mask routing contract rather than generic chain stability.
//

import XCTest
@testable import DCRenderKit
import Metal

final class PortraitBlurMaskPipelineTests: XCTestCase {

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

    // MARK: - Spatial selectivity

    /// Half-subject / half-background mask.
    ///
    /// Source is a vertical ramp (value varies with `y`, uniform across
    /// `x`); mask is a horizontal split (left half = subject / right half
    /// = background). Because the ramp varies orthogonally to the mask
    /// split, horizontal Poisson sampling averages ramp values at the
    /// same `y` and produces the same output as the input in the subject
    /// half — any drift in the subject half would indicate the filter
    /// applied blur despite `blurAmount = 0`.
    ///
    /// ## Why this isolates the mask-routing contract
    ///
    /// `PortraitBlurFilter.passes(input:)` declares both passes to
    /// consume `.additional(0)` as texture(2). If either pass failed to
    /// look up `additionalInputs[0]` — or if `MultiPassExecutor` failed
    /// to thread the filter-level `additionalInputs` array into the
    /// pass input resolver — the shader would read the mask texture as
    /// zero (or garbage), giving `blurAmount = (1 − 0) · strength = 1`
    /// at every pixel and homogenising the subject half into the ramp
    /// mean. The subject-half tight tolerance (0.03) is well under the
    /// ramp's peak-to-peak 1.0, so that regression would surface
    /// immediately.
    ///
    /// Also covers two-pass symmetry: if pass 2 alone failed to receive
    /// the mask, pass 1's correct subject-sharp output would be
    /// re-blurred by pass 2's uniform blur, again drifting the subject
    /// half.
    func testMaskDrivenSpatialSelectivity() throws {
        let width = 128
        let height = 128
        let source = try makeCheckerSource(width: width, height: height)
        let mask = try makeHalfHorizontalMask(
            width: width, height: height, subjectLeftHalf: true
        )

        let output = try runPortraitBlur(
            source: source,
            strength: 100,
            maskTexture: mask
        )
        let outPixels = try readTexture(output)
        let srcPixels = try readTexture(source)

        // Subject half (x < width/2). `blurAmount = (1 − 1) · strength = 0`
        // ⇒ output pixel must equal source pixel within Float16 round-trip
        // + tiny numerical noise. Tight tolerance 0.03 would catch any
        // pass-2 mask drop that would otherwise average neighbours in.
        for y in 20..<(height - 20) {
            for x in 20..<(width / 2 - 20) {
                XCTAssertEqual(
                    outPixels[y][x].r, srcPixels[y][x].r,
                    accuracy: 0.03,
                    "subject half should stay sharp at (\(x), \(y))"
                )
            }
        }

        // Background half: blur must have fired. Report the maximum
        // absolute per-pixel drift in the interior (avoiding edge
        // clamp) and require at least one pixel drifts past 0.02 —
        // Poisson averaging of a vertical ramp should move each pixel
        // by at least that across a 128-px short side at strength=100.
        var maxBgDrift: Float = 0
        for y in 20..<(height - 20) {
            for x in (width / 2 + 20)..<(width - 20) {
                let drift = abs(outPixels[y][x].r - srcPixels[y][x].r)
                if drift > maxBgDrift {
                    maxBgDrift = drift
                }
            }
        }
        // Expected drift magnitude: checker boundary pixels average
        // 0.3 and 0.7 neighbours under Poisson blur, landing near 0.5
        // ⇒ drift ≈ 0.2. Threshold 0.1 leaves a 2× margin for the
        // strict-interior pixels far from block boundaries (where drift
        // would be smaller).
        XCTAssertGreaterThan(
            maxBgDrift, 0.1,
            "background half must show measurable Poisson-disc blur; max drift was \(maxBgDrift)"
        )
    }

    // MARK: - Realistic DigiCam-style edit chain

    /// Masked PortraitBlur surrounded by tone / color / sharpening
    /// filters.
    ///
    /// ## Why this adds coverage
    ///
    /// Unit tests exercise PortraitBlur in isolation (one step in the
    /// pipeline). DigiCam's real usage puts it mid-chain: Exposure /
    /// Contrast already rendered to `rgba16Float`, then PortraitBlur
    /// reads that intermediate + the caller-supplied mask, then
    /// Saturation / Sharpen read PortraitBlur's output. This test
    /// verifies:
    ///
    ///   - The filter struct's `additionalInputs` (mask) survives
    ///     through the pipeline's step-to-step texture handoff (each
    ///     step's output becomes the next step's source, but the
    ///     filter's own additional inputs must NOT be replaced by the
    ///     chained intermediate).
    ///   - Multi-pass filter embedded between single-pass filters
    ///     composes cleanly — no encoder state leaks, no pool hazards.
    ///   - Mask spatial selectivity still resolves correctly at the
    ///     chain's output, after upstream filters have modified the
    ///     ramp values PortraitBlur averages over.
    func testDigiCamStyleEditChainConsumesMaskMidChain() throws {
        let width = 128
        let height = 128
        let source = try makeCheckerSource(width: width, height: height)
        let mask = try makeHalfHorizontalMask(
            width: width, height: height, subjectLeftHalf: true
        )

        let steps: [AnyFilter] = [
            .single(ExposureFilter(exposure: 5, colorSpace: .linear)),
            .single(ContrastFilter(
                contrast: 10, lumaMean: 0.5, colorSpace: .linear
            )),
            .multi(PortraitBlurFilter(strength: 80, maskTexture: mask)),
            .single(SaturationFilter(saturation: 1.1)),
            .single(SharpenFilter(amount: 20, step: 1.0)),
        ]

        let pipeline = Pipeline(
            input: .texture(source),
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
        let output = try pipeline.outputSync()

        XCTAssertEqual(output.width, width)
        XCTAssertEqual(output.height, height)
        XCTAssertEqual(output.pixelFormat, .rgba16Float)

        // Subject vs background asymmetry survives the full chain: the
        // background half is the one PortraitBlur homogenised, so its
        // interior stddev should be smaller than the subject half's
        // (which preserves the source's vertical gradient, only
        // reshaped slightly by Sharpen).
        let outPixels = try readTexture(output)
        let subjStddev = columnStddev(
            outPixels, xRange: 20..<(width / 2 - 20), yRange: 20..<(height - 20)
        )
        let bgStddev = columnStddev(
            outPixels, xRange: (width / 2 + 20)..<(width - 20), yRange: 20..<(height - 20)
        )
        XCTAssertGreaterThan(
            subjStddev, bgStddev,
            "subject half should retain more vertical-ramp variance than blurred background"
        )
    }

    // MARK: - Mask / source resolution mismatch

    /// Mask is half the resolution of the source.
    ///
    /// Exercises `PortraitBlurFilter.metal`'s
    /// `dcr_portraitBlurMaskSample` coordinate remap
    /// (`gid / inputW * maskW`), which DigiCam relies on because Vision
    /// may return a mask at the detection resolution rather than the
    /// filter source resolution.
    ///
    /// The half-horizontal mask split remains the dominant signal; we
    /// allow a small tolerance band around the half-width boundary
    /// where the mask's nearest-neighbour remap straddles the split.
    func testMaskResolutionMismatchWorks() throws {
        let srcWidth = 128
        let srcHeight = 128
        let maskWidth = 64
        let maskHeight = 64

        let source = try makeCheckerSource(width: srcWidth, height: srcHeight)
        let mask = try makeHalfHorizontalMask(
            width: maskWidth, height: maskHeight, subjectLeftHalf: true
        )

        let output = try runPortraitBlur(
            source: source,
            strength: 100,
            maskTexture: mask
        )
        let outPixels = try readTexture(output)
        let srcPixels = try readTexture(source)

        // Subject half: mask nearest-neighbour maps x∈[0, srcWidth/2)
        // → maskX∈[0, maskWidth/2) = fully in the subject half of the
        // mask. Output should equal source.
        for y in 20..<(srcHeight - 20) {
            for x in 20..<(srcWidth / 2 - 20) {
                XCTAssertEqual(
                    outPixels[y][x].r, srcPixels[y][x].r,
                    accuracy: 0.03,
                    "subject half (remapped mask) should stay sharp at (\(x), \(y))"
                )
            }
        }

        // Background half: confirm blur fired (some pixel drifted past
        // 0.02) to prove the mask remap didn't accidentally mark the
        // whole texture subject.
        var maxBgDrift: Float = 0
        for y in 20..<(srcHeight - 20) {
            for x in (srcWidth / 2 + 20)..<(srcWidth - 20) {
                let drift = abs(outPixels[y][x].r - srcPixels[y][x].r)
                if drift > maxBgDrift {
                    maxBgDrift = drift
                }
            }
        }
        // Expected drift magnitude: checker boundary pixels average
        // 0.3 and 0.7 neighbours under Poisson blur, landing near 0.5
        // ⇒ drift ≈ 0.2. Threshold 0.1 leaves a 2× margin for the
        // strict-interior pixels far from block boundaries (where drift
        // would be smaller).
        XCTAssertGreaterThan(
            maxBgDrift, 0.1,
            "background half must blur despite mask at half resolution; max drift was \(maxBgDrift)"
        )
    }

    // MARK: - Helpers

    private func runPortraitBlur(
        source: MTLTexture,
        strength: Float,
        maskTexture: MTLTexture?
    ) throws -> MTLTexture {
        let pipeline = Pipeline(
            input: .texture(source),
            steps: [.multi(PortraitBlurFilter(
                strength: strength, maskTexture: maskTexture
            ))],
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

    /// Per-column standard deviation of the red channel, averaged
    /// across the requested column range. Used as a quick proxy for
    /// "how much vertical-ramp structure survives" when comparing
    /// subject vs. blurred background halves.
    private func columnStddev(
        _ pixels: [[Pixel]],
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Float {
        var totalStddev: Float = 0
        var columnCount = 0
        for x in xRange {
            var sum: Float = 0
            var sumSq: Float = 0
            var n: Float = 0
            for y in yRange {
                let v = pixels[y][x].r
                sum += v
                sumSq += v * v
                n += 1
            }
            guard n > 0 else { continue }
            let mean = sum / n
            let variance = max(0, sumSq / n - mean * mean)
            totalStddev += variance.squareRoot()
            columnCount += 1
        }
        return columnCount > 0 ? totalStddev / Float(columnCount) : 0
    }
}

// MARK: - Synthetic texture builders (fileprivate, self-contained)

private struct Pixel {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

/// 8×8-block checkerboard alternating between 0.3 and 0.7 grey. High-
/// frequency signal is essential for PortraitBlur tests: a spatially
/// linear source (e.g. vertical ramp) is an eigenfunction of a
/// symmetric box / Poisson kernel so blur ≈ identity, and asserting
/// "blur changes the output" would require unrealistically tight
/// tolerances. A checker with 8-pixel blocks vs. PortraitBlur's
/// `localRadius ≈ 3.8 px` at 128×128 / strength=100 gives a clean
/// signal: block interiors survive, block boundaries smear toward the
/// 0.5 midpoint.
private func makeCheckerSource(width: Int, height: Int) throws -> MTLTexture {
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

    let blockSize = 8
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let ha = Float16(1.0).bitPattern
    for y in 0..<height {
        for x in 0..<width {
            let bx = x / blockSize
            let by = y / blockSize
            let v: Float = ((bx + by) & 1 == 0) ? 0.3 : 0.7
            let h = Float16(v).bitPattern
            let off = (y * width + x) * 4
            pixels[off + 0] = h
            pixels[off + 1] = h
            pixels[off + 2] = h
            pixels[off + 3] = ha
        }
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

/// R8Unorm mask texture split horizontally.
///
/// - `subjectLeftHalf = true`: left half = 255 (subject), right half = 0
///   (background).
/// - `subjectLeftHalf = false`: flipped.
private func makeHalfHorizontalMask(
    width: Int, height: Int, subjectLeftHalf: Bool
) throws -> MTLTexture {
    guard let device = Device.tryShared?.metalDevice else {
        throw XCTSkip("Metal device required")
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm,
        width: width, height: height, mipmapped: false
    )
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

    var bytes = [UInt8](repeating: 0, count: width * height)
    let leftValue: UInt8 = subjectLeftHalf ? 255 : 0
    let rightValue: UInt8 = subjectLeftHalf ? 0 : 255
    for y in 0..<height {
        for x in 0..<width {
            bytes[y * width + x] = (x < width / 2) ? leftValue : rightValue
        }
    }
    bytes.withUnsafeBufferPointer { ptr in
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: ptr.baseAddress!,
            bytesPerRow: width
        )
    }
    return tex
}

/// Reads an `rgba16Float` texture into a row-major `[[Pixel]]` array.
/// Blits through a shared-storage staging texture so `getBytes` works
/// on private-storage pipeline outputs.
private func readTexture(_ texture: MTLTexture) throws -> [[Pixel]] {
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
    try BlitDispatcher.copy(
        source: texture, destination: staging, commandBuffer: commandBuffer
    )
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
    var result: [[Pixel]] = []
    for y in 0..<height {
        var row: [Pixel] = []
        for x in 0..<width {
            let offset = (y * width + x) * 4
            row.append(Pixel(
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
