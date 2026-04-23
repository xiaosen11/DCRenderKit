//
//  ContractTestHelpers.swift
//  DCRenderKitTests
//
//  Shared infrastructure for `docs/contracts/*.md` verification tests.
//  Provides:
//
//  - `ContractTestCase` base class with device / caches / pool and
//    texture helpers, so individual contract test files only worry
//    about assertions.
//  - Swift mirrors of the OKLab / OKLCh forward / inverse transforms
//    (Ottosson 2020 matrices). These are **intentionally independent**
//    of the Metal shader implementation: assertion expected values are
//    derived from the same first-principles matrices the shader uses,
//    but compiled and executed entirely on the CPU. A bug in the shader
//    will therefore produce a measurable mismatch against the Swift
//    reference rather than being silently "validated" by two copies of
//    the same bug.
//  - Lindbloom / BabelColor canonical ColorChecker patch constants
//    (8-bit sRGB from en.wikipedia.org/wiki/ColorChecker, converted to
//    linear sRGB via IEC 61966-2-1 piecewise inverse gamma).
//  - A GPU-side OKLCh measurement helper that runs filter output
//    through `DCROKLabExposeLChTestKernel` (declared in
//    `Foundation/OKLab.metal`) and returns the (L, C, h) triple.
//  - A synthetic patch constructor that starts from (L, C, h) in OKLCh
//    and returns the corresponding linear-sRGB triple, used by contract
//    clauses that need two samples at identical chroma and differing
//    hue (e.g. Vibrance skin-protect vs non-skin comparison).
//
//  References:
//    Ottosson (2020) — https://bottosson.github.io/posts/oklab/
//    ColorChecker canonical sRGB — https://en.wikipedia.org/wiki/ColorChecker
//

import XCTest
@testable import DCRenderKit
import Metal
import simd

// MARK: - Base class

class ContractTestCase: XCTestCase {

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

    // MARK: - Texture construction

    func makeSinglePatchTexture(
        _ rgb: SIMD3<Float>, width: Int = 8, height: Int = 8
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
        let hr = Float16(rgb.x).bitPattern
        let hg = Float16(rgb.y).bitPattern
        let hb = Float16(rgb.z).bitPattern
        let ha = Float16(1.0).bitPattern
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

    // MARK: - Pipeline run

    func runFilter<F: FilterProtocol>(
        source: MTLTexture, filter: F
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

    /// Same as `runFilter` but for `MultiPassFilter` — wraps the filter
    /// in a `.multi(...)` pipeline step rather than `.single(...)`.
    func runMultiPassFilter<F: MultiPassFilter>(
        source: MTLTexture, filter: F
    ) throws -> MTLTexture {
        let pipeline = Pipeline(
            input: .texture(source),
            steps: [.multi(filter)],
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

    // MARK: - Pixel read

    func readCentrePixel(_ texture: MTLTexture) throws -> SIMD4<Float> {
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
        return SIMD4<Float>(
            Float(Float16(bitPattern: raw[offset + 0])),
            Float(Float16(bitPattern: raw[offset + 1])),
            Float(Float16(bitPattern: raw[offset + 2])),
            Float(Float16(bitPattern: raw[offset + 3]))
        )
    }

    // MARK: - OKLCh measurement (GPU side, via shader test kernel)

    /// Runs `input` through `filter`, then through the OKLCh-expose
    /// kernel from `Foundation/OKLab.metal`, and returns (L, C, h).
    func measureOutputOKLCh<F: FilterProtocol>(
        input: SIMD3<Float>, filter: F
    ) throws -> SIMD3<Float> {
        let source = try makeSinglePatchTexture(input)
        let filtered = try runFilter(source: source, filter: filter)
        let lchTex = try runFilter(source: filtered, filter: OKLabExposeLChContractFilter())
        let p = try readCentrePixel(lchTex)
        return SIMD3<Float>(p.x, p.y, p.z)
    }

    /// Same as above but skips the filter — measures input's OKLCh
    /// through the shader path, letting tests compare GPU and Swift
    /// expectations for identity cases.
    func measureInputOKLCh(_ input: SIMD3<Float>) throws -> SIMD3<Float> {
        let source = try makeSinglePatchTexture(input)
        let lchTex = try runFilter(source: source, filter: OKLabExposeLChContractFilter())
        let p = try readCentrePixel(lchTex)
        return SIMD3<Float>(p.x, p.y, p.z)
    }
}

// MARK: - OKLab Swift mirror (Ottosson 2020 matrices)
//
// Independent re-implementation on the CPU. Used to derive expected
// OKLCh values in assertions without running the shader.
//
// Cross-validation: `OKLabSwiftMirrorTests` asserts these functions
// against Ottosson's published reference values for white / red /
// green / blue (within 0.005). If Swift and Metal agree with those
// references AND agree with each other on arbitrary inputs, the
// matrix math is correct in both places.

enum OKLab {

    // Forward

    static func linearSRGBToOKLab(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * Double(rgb.x) + 0.5363325363 * Double(rgb.y) + 0.0514459929 * Double(rgb.z)
        let m = 0.2119034982 * Double(rgb.x) + 0.6806995451 * Double(rgb.y) + 0.1073969566 * Double(rgb.z)
        let s = 0.0883024619 * Double(rgb.x) + 0.2817188376 * Double(rgb.y) + 0.6299787005 * Double(rgb.z)

        let l_ = cbrtSigned(l)
        let m_ = cbrtSigned(m)
        let s_ = cbrtSigned(s)

        return SIMD3<Float>(
            Float(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_),
            Float(1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_),
            Float(0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)
        )
    }

    static func okLabToLinearSRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = Double(lab.x) + 0.3963377774 * Double(lab.y) + 0.2158037573 * Double(lab.z)
        let m_ = Double(lab.x) - 0.1055613458 * Double(lab.y) - 0.0638541728 * Double(lab.z)
        let s_ = Double(lab.x) - 0.0894841775 * Double(lab.y) - 1.2914855480 * Double(lab.z)

        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_

        return SIMD3<Float>(
            Float( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            Float(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            Float(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    static func okLabToOKLCh(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let C = sqrt(lab.y * lab.y + lab.z * lab.z)
        let h = atan2(lab.z, lab.y)
        return SIMD3<Float>(lab.x, C, h)
    }

    static func okLChToOKLab(_ lch: SIMD3<Float>) -> SIMD3<Float> {
        return SIMD3<Float>(lch.x, lch.y * cos(lch.z), lch.y * sin(lch.z))
    }

    // Convenience

    static func linearSRGBToOKLCh(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        return okLabToOKLCh(linearSRGBToOKLab(rgb))
    }

    /// `sign(x) · |x|^(1/3)`; handles negative inputs without NaN.
    private static func cbrtSigned(_ x: Double) -> Double {
        return x.sign == .minus ? -pow(-x, 1.0 / 3.0) : pow(x, 1.0 / 3.0)
    }
}

// MARK: - sRGB gamma

enum SRGBGamma {
    /// Inverse sRGB (IEC 61966-2-1). 8-bit RGB → linear sRGB in [0, 1].
    static func decode8Bit(_ rgb: SIMD3<UInt8>) -> SIMD3<Float> {
        return SIMD3<Float>(decode(channel: rgb.x), decode(channel: rgb.y), decode(channel: rgb.z))
    }

    private static func decode(channel: UInt8) -> Float {
        let x = Float(channel) / 255.0
        if x <= 0.04045 {
            return x / 12.92
        }
        return powf((x + 0.055) / 1.055, 2.4)
    }
}

// MARK: - Test patches (Macbeth ColorChecker)

/// Canonical Macbeth ColorChecker patches from Wikipedia's table,
/// which aggregates BabelColor / Lindbloom measurements. 8-bit sRGB
/// (D65), decoded to linear sRGB via IEC 61966-2-1.
///
/// Source: https://en.wikipedia.org/wiki/ColorChecker
enum ColorCheckerPatch {
    static let darkSkin     = SRGBGamma.decode8Bit(SIMD3<UInt8>(115,  82,  68))   // #1
    static let lightSkin    = SRGBGamma.decode8Bit(SIMD3<UInt8>(194, 150, 130))   // #2
    static let blueSky      = SRGBGamma.decode8Bit(SIMD3<UInt8>( 98, 122, 157))   // #3
    static let foliage      = SRGBGamma.decode8Bit(SIMD3<UInt8>( 87, 108,  67))   // #4
    static let orange       = SRGBGamma.decode8Bit(SIMD3<UInt8>(214, 126,  44))   // #7
    static let bluishGreen  = SRGBGamma.decode8Bit(SIMD3<UInt8>(103, 189, 170))   // #6
    static let moderateRed  = SRGBGamma.decode8Bit(SIMD3<UInt8>(193,  90,  99))   // #9
    static let purplishBlue = SRGBGamma.decode8Bit(SIMD3<UInt8>( 80,  91, 166))   // #8
    static let cyan         = SRGBGamma.decode8Bit(SIMD3<UInt8>(  8, 133, 161))   // #18
    static let macbethRed   = SRGBGamma.decode8Bit(SIMD3<UInt8>(175,  54,  60))   // #15
    static let macbethGreen = SRGBGamma.decode8Bit(SIMD3<UInt8>( 70, 148,  73))   // #14
    static let macbethBlue  = SRGBGamma.decode8Bit(SIMD3<UInt8>( 56,  61, 150))   // #13
}

/// Synthetic patches + pure sRGB primaries for gamut-edge / near-grey
/// tests. These are *not* Macbeth values — they're chosen for specific
/// contract clauses.
enum TestPatch {
    static let black        = SIMD3<Float>(0, 0, 0)
    static let midGrey      = SIMD3<Float>(0.5, 0.5, 0.5)
    static let nearBlackGrey = SIMD3<Float>(0.2, 0.2, 0.2)
    static let highGrey     = SIMD3<Float>(0.8, 0.8, 0.8)
    static let white        = SIMD3<Float>(1, 1, 1)
    static let pureRed      = SIMD3<Float>(1, 0, 0)
    static let pureGreen    = SIMD3<Float>(0, 1, 0)
    static let pureBlue     = SIMD3<Float>(0, 0, 1)
    static let pureCyan     = SIMD3<Float>(0, 1, 1)
    static let pureMagenta  = SIMD3<Float>(1, 0, 1)
    static let pureYellow   = SIMD3<Float>(1, 1, 0)
}

// MARK: - Zone System reference values (linear sRGB Y)
//
// Derived from Norman Koren's simplified Zone System, which places
// 8-bit gamma-encoded midpoints of the ten zones at
// 13, 38, 64, 90, 115, 141, 166, 192, 218, 243 (Zones I through X).
// Wikipedia's Zone System article puts Zone V at 18 % reflectance,
// which aligns with the gamma-encoded 115 / 255 → linear ≈ 0.169.
//
// Inverse sRGB via IEC 61966-2-1 piecewise. Precomputed here (not at
// load time) so the constants are callable from `static let` in other
// files without initialization-order worries.

enum ZoneY {
    /// Zone III — Shadows with detail. Linear Y ≈ 0.052 (gamma 0.251).
    static let zoneIII: Float = 0.0516
    /// Zone V — Middle grey (18 % reflectance). Linear Y ≈ 0.169.
    static let zoneV: Float = 0.169
    /// Zone VII — Highlights with detail. Linear Y ≈ 0.382 (gamma 0.651).
    static let zoneVII: Float = 0.382
    /// Mid-tone edge just above Zone IV. Used by HS C.4 midtone stability.
    static let midTone: Float = 0.2
}

// MARK: - Multi-pixel texture construction

extension ContractTestCase {

    /// Build a `width × height` texture where each pixel's linear sRGB
    /// is supplied by `pixelAt(x, y) -> SIMD3<Float>`. Alpha = 1.
    /// Texture format: rgba16Float.
    func makeTexture(
        width: Int, height: Int,
        pixelAt: (Int, Int) -> SIMD3<Float>
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
        let ha = Float16(1.0).bitPattern
        for y in 0..<height {
            for x in 0..<width {
                let rgb = pixelAt(x, y)
                let offset = (y * width + x) * 4
                pixels[offset + 0] = Float16(rgb.x).bitPattern
                pixels[offset + 1] = Float16(rgb.y).bitPattern
                pixels[offset + 2] = Float16(rgb.z).bitPattern
                pixels[offset + 3] = ha
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

    /// Uniform neutral-grey patch at linear Y. Alpha = 1.
    func makeUniformGrey(
        linearY: Float, width: Int = 8, height: Int = 8
    ) throws -> MTLTexture {
        return try makeSinglePatchTexture(
            SIMD3<Float>(linearY, linearY, linearY),
            width: width, height: height
        )
    }

    /// Sharp half-plane step: left half at `leftY`, right half at `rightY`,
    /// both grey (R = G = B). No blur. Useful for edge-preservation tests.
    func makeSharpStep(
        width: Int = 64, height: Int = 64,
        leftY: Float, rightY: Float
    ) throws -> MTLTexture {
        return try makeTexture(width: width, height: height) { x, _ in
            let y = x < width / 2 ? leftY : rightY
            return SIMD3<Float>(y, y, y)
        }
    }

    /// Gaussian-blurred horizontal step. Useful for HS halo measurement
    /// where a sharp step would be smoothed by the filter's own guided
    /// filter, confounding the halo signal.
    ///
    /// The blur is computed per-column via a 1-D Gaussian; rows are
    /// uniform. Sigma in pixels (e.g. σ=2 spreads transition over ~6 px).
    func makeSoftEdgeStep(
        width: Int = 64, height: Int = 64,
        leftY: Float, rightY: Float, sigma: Float
    ) throws -> MTLTexture {
        let midX = Float(width / 2) - 0.5
        var columnY = [Float](repeating: leftY, count: width)
        for x in 0..<width {
            // Cumulative normal at (x - midX) / σ, maps [0, 1] transition.
            let z = (Float(x) - midX) / sigma
            // Fast erf approximation via tanh: cdf(z) ≈ 0.5·(1 + tanh(1.2 z))
            let cdf = 0.5 * (1.0 + Foundation.tanh(1.2 * z))
            columnY[x] = leftY + (rightY - leftY) * cdf
        }
        return try makeTexture(width: width, height: height) { x, _ in
            let v = columnY[x]
            return SIMD3<Float>(v, v, v)
        }
    }

    /// Checker pattern in gamma-Y space. `blockPx` = block size on each
    /// axis (e.g. 8 for 8×8 blocks). Two linear-Y values alternate.
    func makeCheckerTexture(
        width: Int = 64, height: Int = 64,
        blockPx: Int, darkY: Float, brightY: Float
    ) throws -> MTLTexture {
        return try makeTexture(width: width, height: height) { x, y in
            let bx = (x / blockPx) % 2
            let by = (y / blockPx) % 2
            let v = (bx ^ by) == 0 ? darkY : brightY
            return SIMD3<Float>(v, v, v)
        }
    }

    /// Horizontal linear ramp of grey: `yLeft` at x=0, `yRight` at x=W-1.
    func makeHorizontalRamp(
        width: Int = 64, height: Int = 64,
        yLeft: Float, yRight: Float
    ) throws -> MTLTexture {
        return try makeTexture(width: width, height: height) { x, _ in
            let t = width <= 1 ? 0 : Float(x) / Float(width - 1)
            let v = yLeft + (yRight - yLeft) * t
            return SIMD3<Float>(v, v, v)
        }
    }

    /// Centre bright spot: `spotSize × spotSize` block at `brightY`
    /// (grey), background at `backgroundY`. Used by SoftGlow C.4
    /// spatial-spread test.
    func makeCentreBrightSpot(
        size: Int = 64, spotSize: Int = 4,
        brightY: Float, backgroundY: Float = 0.0
    ) throws -> MTLTexture {
        let low = (size - spotSize) / 2
        let high = low + spotSize
        return try makeTexture(width: size, height: size) { x, y in
            let inSpot = x >= low && x < high && y >= low && y < high
            let v = inSpot ? brightY : backgroundY
            return SIMD3<Float>(v, v, v)
        }
    }

    // MARK: - Multi-pixel read

    /// Read an entire texture back as a 2-D `[row][col]` array of linear
    /// sRGB (R, G, B); alpha dropped. Rec.709 luma computable by
    /// `lumaGrid`.
    func readRGBGrid(_ texture: MTLTexture) throws -> [[SIMD3<Float>]] {
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
        var grid = [[SIMD3<Float>]]()
        grid.reserveCapacity(texture.height)
        for y in 0..<texture.height {
            var row = [SIMD3<Float>]()
            row.reserveCapacity(texture.width)
            for x in 0..<texture.width {
                let offset = (y * texture.width + x) * 4
                row.append(SIMD3<Float>(
                    Float(Float16(bitPattern: raw[offset + 0])),
                    Float(Float16(bitPattern: raw[offset + 1])),
                    Float(Float16(bitPattern: raw[offset + 2]))
                ))
            }
            grid.append(row)
        }
        return grid
    }

    /// Rec.709 luma grid from an RGB grid.
    func lumaGrid(_ rgb: [[SIMD3<Float>]]) -> [[Float]] {
        let lumaWeights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        return rgb.map { row in row.map { simd_dot($0, lumaWeights) } }
    }
}

// MARK: - Luma measurements

enum LumaStats {
    /// Mean-squared deviation from the grid mean. Sanity metric for
    /// "texture energy" — used by Clarity C.2 monotonicity.
    static func variance(_ luma: [[Float]]) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for row in luma { for v in row { sum += v; count += 1 } }
        let mean = count > 0 ? sum / count : 0
        var ssd: Float = 0
        for row in luma { for v in row { ssd += (v - mean) * (v - mean) } }
        return count > 0 ? ssd / count : 0
    }

    /// max − min across the grid.
    static func amplitude(_ luma: [[Float]]) -> Float {
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for row in luma {
            for v in row { if v < lo { lo = v }; if v > hi { hi = v } }
        }
        return (hi.isFinite && lo.isFinite) ? hi - lo : 0
    }

    /// Peak positive overshoot above `ceiling` in the stated column
    /// range (inclusive). Used by HS/Clarity halo measurement.
    static func peakOvershoot(
        _ luma: [[Float]], ceiling: Float, xRange: ClosedRange<Int>
    ) -> Float {
        var peak: Float = 0
        for row in luma {
            for x in xRange.lowerBound...xRange.upperBound where x < row.count {
                let over = row[x] - ceiling
                if over > peak { peak = over }
            }
        }
        return peak
    }

    /// Peak negative undershoot below `floor` in the stated column range.
    static func peakUndershoot(
        _ luma: [[Float]], floor: Float, xRange: ClosedRange<Int>
    ) -> Float {
        var peak: Float = 0
        for row in luma {
            for x in xRange.lowerBound...xRange.upperBound where x < row.count {
                let under = floor - row[x]
                if under > peak { peak = under }
            }
        }
        return peak
    }
}

// MARK: - Synthetic OKLCh → linear sRGB patch construction

/// Build a linear-sRGB patch from OKLCh coordinates. Throws if the
/// synthesized RGB falls outside `[0, 1]³` by more than the gamut
/// margin — callers must choose feasible (L, C, h) triples (e.g. low
/// C at extreme L is usually safe).
func synthesizePatchFromOKLCh(L: Float, C: Float, hRadians: Float) throws -> SIMD3<Float> {
    let rgb = OKLab.okLabToLinearSRGB(OKLab.okLChToOKLab(SIMD3<Float>(L, C, hRadians)))
    let margin: Float = 1.0 / 256.0  // gentle tolerance for edge cases
    if rgb.x < -margin || rgb.x > 1.0 + margin
        || rgb.y < -margin || rgb.y > 1.0 + margin
        || rgb.z < -margin || rgb.z > 1.0 + margin {
        struct OutOfGamut: Error {
            let rgb: SIMD3<Float>
            let L: Float; let C: Float; let h: Float
        }
        throw OutOfGamut(rgb: rgb, L: L, C: C, h: hRadians)
    }
    // Clamp tiny floating-point excursions so the Float16 textures
    // don't panic on values like 1.0002.
    return SIMD3<Float>(
        max(0.0, min(1.0, rgb.x)),
        max(0.0, min(1.0, rgb.y)),
        max(0.0, min(1.0, rgb.z))
    )
}

// MARK: - OKLab expose filter (Contract-test-only wrapper)

/// Wraps `DCROKLabExposeLChTestKernel` (defined in
/// `Foundation/OKLab.metal`) as a `FilterProtocol` so contract tests
/// can pipe arbitrary filter output through it. Kept private to this
/// file; `OKLabConversionTests` has its own copy for the same reason.
struct OKLabExposeLChContractFilter: FilterProtocol {
    var modifier: ModifierEnum { .compute(kernel: "DCROKLabExposeLChTestKernel") }
    var uniforms: FilterUniforms { .empty }
    static var fuseGroup: FuseGroup? { nil }
}
