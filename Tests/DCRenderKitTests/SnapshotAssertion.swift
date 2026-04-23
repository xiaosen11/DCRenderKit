//
//  SnapshotAssertion.swift
//  DCRenderKitTests
//
//  Minimal snapshot-regression harness for filter output textures.
//  Renders a Metal texture to an 8-bit PNG, stores it as a baseline
//  alongside the test source tree, and fails future runs on drift.
//
//  ## Usage
//
//    func testMyFilterBaseline() throws {
//        let output = try runMyFilter()
//        try SnapshotAssertion.assertMatchesBaseline(
//            output,
//            named: "MyFilter_default",
//            maxChannelDrift: 0.02
//        )
//    }
//
//  ## Baseline workflow
//
//    - First run with a new `named:` has no baseline on disk. The
//      harness writes the current output to
//      `Tests/DCRenderKitTests/__Snapshots__/<named>.png` and throws
//      `XCTSkip("baseline saved, re-run to assert")`. Commit the PNG
//      so CI has it; subsequent runs will compare.
//    - Later runs load the baseline, compare per-pixel max |Δ|
//      against `maxChannelDrift`, and fail with the offending
//      coordinate if exceeded.
//    - To refresh baselines after an intentional filter change,
//      delete the PNG (or use the "re-record" convenience below)
//      and re-run.
//
//  ## Design trade-offs
//
//    - **8-bit PNG** for baselines: legible in diff tools, trivial
//      to git-track, lossy at the precision floor (1/255 ≈ 0.4 %).
//      `maxChannelDrift = 0.02` is comfortable over this floor.
//      Float16 HDR content that matters for the baseline at > 1.0
//      would demand a float-format baseline — a Phase 2 item if it
//      surfaces. Tier 4 aesthetic filters (FilmGrain / CCD /
//      PortraitBlur) are LDR by design.
//    - **Max-channel |Δ|** instead of SSIM: a per-pixel bound is
//      conservative (SSIM averages drift across structure) and
//      diagnoses the exact failing pixel. Perceptual-aware metrics
//      can layer on top without replacing this primitive.
//    - **Relative-to-source** baseline storage: baselines live next
//      to the test file that owns them, not in a test-bundle
//      resource. This lets git diffs / reviews see them naturally.
//

import XCTest
@testable import DCRenderKit
import Metal
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Baseline comparison primitive for visual-regression tests.
enum SnapshotAssertion {

    // MARK: - Public API

    /// Assert that `texture`'s visible content matches the stored
    /// baseline named `named` (a `.png` under `__Snapshots__/`).
    ///
    /// - Parameters:
    ///   - texture: The filter output to compare. Any 4-channel
    ///     pixel format is supported; the harness downsamples to
    ///     8-bit sRGB for the on-disk comparison.
    ///   - named: Stable short identifier, safe as a filename.
    ///   - maxChannelDrift: Per-channel, per-pixel |Δ| threshold in
    ///     `[0, 1]` units (normalised 8-bit). Values above this
    ///     magnitude in any channel at any pixel fail the test.
    ///     Default 0.02 ≈ 5 out of 255 — above the 8-bit
    ///     quantisation floor, below the "looks different" threshold
    ///     a human would call a regression.
    ///   - file / line: Forwarded to `XCTFail` for precise failure
    ///     locations.
    static func assertMatchesBaseline(
        _ texture: MTLTexture,
        named: String,
        maxChannelDrift: Double = 0.02,
        file: StaticString = #filePath,
        line: UInt = #line,
        snapshotsDirectory: URL? = nil
    ) throws {
        let actualPNG = try pngData(from: texture)
        let baselineURL = try resolveBaselineURL(
            named: named,
            snapshotsDirectory: snapshotsDirectory
        )

        // Missing baseline → save + skip with explicit guidance.
        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            try saveBaseline(pngData: actualPNG, to: baselineURL)
            throw XCTSkip(
                "Baseline saved to \(baselineURL.path). Commit and re-run to assert."
            )
        }

        // Present: compare per-pixel.
        guard let baselineData = try? Data(contentsOf: baselineURL) else {
            XCTFail(
                "Could not read baseline at \(baselineURL.path)",
                file: file, line: line
            )
            return
        }
        let actualImage = try decodePNG(actualPNG)
        let baselineImage = try decodePNG(baselineData)

        guard actualImage.width == baselineImage.width,
              actualImage.height == baselineImage.height else {
            XCTFail(
                "Baseline size \(baselineImage.width)×\(baselineImage.height) " +
                "does not match actual \(actualImage.width)×\(actualImage.height) " +
                "for snapshot '\(named)'",
                file: file, line: line
            )
            return
        }

        // Max / mean channel drift over the whole grid.
        let report = compareBitmaps(actualImage, baselineImage)
        if report.maxChannelDrift > maxChannelDrift {
            XCTFail(
                """
                Snapshot '\(named)' drifted beyond tolerance.
                  max channel |Δ| = \(String(format: "%.4f", report.maxChannelDrift)) > \(maxChannelDrift)
                  at pixel (\(report.peakPixel.x), \(report.peakPixel.y)), channel \(report.peakChannel)
                  mean channel |Δ| = \(String(format: "%.4f", report.meanChannelDrift))
                  baseline: \(baselineURL.path)
                Re-record intentionally if the filter semantics changed: delete \
                the baseline PNG and re-run.
                """,
                file: file, line: line
            )
        }
    }

    // MARK: - Diagnostics payload

    private struct DiffReport {
        let maxChannelDrift: Double
        let meanChannelDrift: Double
        let peakPixel: (x: Int, y: Int)
        let peakChannel: Int
    }

    // MARK: - Baseline file resolution

    private static func resolveBaselineURL(
        named: String,
        snapshotsDirectory: URL?
    ) throws -> URL {
        if let explicit = snapshotsDirectory {
            try FileManager.default.createDirectory(
                at: explicit,
                withIntermediateDirectories: true
            )
            return explicit.appendingPathComponent("\(named).png")
        }
        // Default: alongside the test source tree.
        let defaultDir = try defaultSnapshotsDirectory()
        try FileManager.default.createDirectory(
            at: defaultDir, withIntermediateDirectories: true
        )
        return defaultDir.appendingPathComponent("\(named).png")
    }

    /// `Tests/DCRenderKitTests/__Snapshots__/`, resolved relative to
    /// this source file's on-disk location. Uses `#filePath` (not
    /// `#file` — that's `#fileID` in Swift 6 and resolves to a
    /// module-relative path, not an absolute one).
    private static func defaultSnapshotsDirectory(
        _ filePath: StaticString = #filePath
    ) throws -> URL {
        let testsSourceURL = URL(fileURLWithPath: String(describing: filePath))
        return testsSourceURL
            .deletingLastPathComponent()  // Tests/DCRenderKitTests/
            .appendingPathComponent("__Snapshots__")
    }

    private static func saveBaseline(pngData: Data, to url: URL) throws {
        try pngData.write(to: url)
    }

    // MARK: - Texture → PNG

    private struct RGBABitmap {
        let width: Int
        let height: Int
        /// Row-major 8-bit RGBA, pre-multiplied alpha unused
        /// (we only care about RGB channels — alpha is constant 1
        /// for filter outputs).
        let bytes: [UInt8]
    }

    /// Render a filter output to 8-bit PNG bytes (sRGB encoded if
    /// source is float-linear, straight 8-bit if source is already
    /// unorm). The conversion policy matches what a consumer would
    /// see on-screen after a standard drawable blit.
    private static func pngData(from texture: MTLTexture) throws -> Data {
        let bitmap = try readBitmap(from: texture)
        guard let cgImage = makeCGImage(from: bitmap) else {
            throw SnapshotError.pngEncodeFailed
        }
        return try encodePNG(cgImage)
    }

    /// Decode a PNG data blob into an 8-bit RGBA bitmap.
    private static func decodePNG(_ data: Data) throws -> RGBABitmap {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SnapshotError.pngDecodeFailed
        }
        let width = cgImage.width
        let height = cgImage.height

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw SnapshotError.bitmapContextFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return RGBABitmap(width: width, height: height, bytes: bytes)
    }

    // MARK: - Texture → RGBABitmap

    private static func readBitmap(from texture: MTLTexture) throws -> RGBABitmap {
        switch texture.pixelFormat {
        case .rgba16Float:
            return try readFloat16(texture)
        case .rgba8Unorm, .rgba8Unorm_srgb:
            return try readRGBA8(texture)
        case .bgra8Unorm, .bgra8Unorm_srgb:
            return try readBGRA8(texture)
        default:
            throw SnapshotError.unsupportedPixelFormat(texture.pixelFormat)
        }
    }

    private static func readFloat16(_ texture: MTLTexture) throws -> RGBABitmap {
        let width = texture.width
        let height = texture.height
        let staging = try makeStagingTexture(like: texture)
        try blitCopy(from: texture, to: staging)

        var raw = [UInt16](repeating: 0, count: width * height * 4)
        raw.withUnsafeMutableBytes { bytes in
            staging.getBytes(
                bytes.baseAddress!,
                bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let r = Float(Float16(bitPattern: raw[i * 4 + 0]))
            let g = Float(Float16(bitPattern: raw[i * 4 + 1]))
            let b = Float(Float16(bitPattern: raw[i * 4 + 2]))
            let a = Float(Float16(bitPattern: raw[i * 4 + 3]))
            bytes[i * 4 + 0] = quantise(r)
            bytes[i * 4 + 1] = quantise(g)
            bytes[i * 4 + 2] = quantise(b)
            bytes[i * 4 + 3] = quantise(a)
        }
        return RGBABitmap(width: width, height: height, bytes: bytes)
    }

    private static func readRGBA8(_ texture: MTLTexture) throws -> RGBABitmap {
        let width = texture.width
        let height = texture.height
        let staging = try makeStagingTexture(like: texture)
        try blitCopy(from: texture, to: staging)

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buf in
            staging.getBytes(
                buf.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return RGBABitmap(width: width, height: height, bytes: bytes)
    }

    private static func readBGRA8(_ texture: MTLTexture) throws -> RGBABitmap {
        var bitmap = try readRGBA8(texture)
        for i in 0..<(bitmap.width * bitmap.height) {
            let b = bitmap.bytes[i * 4 + 0]
            let r = bitmap.bytes[i * 4 + 2]
            var swapped = bitmap.bytes
            swapped[i * 4 + 0] = r
            swapped[i * 4 + 2] = b
            bitmap = RGBABitmap(
                width: bitmap.width, height: bitmap.height, bytes: swapped
            )
        }
        return bitmap
    }

    private static func quantise(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    // MARK: - Bitmap → CGImage / PNG

    private static func makeCGImage(from bitmap: RGBABitmap) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(
            data: Data(bitmap.bytes) as CFData
        ) else {
            return nil
        }
        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func encodePNG(_ cgImage: CGImage) throws -> Data {
        let data = NSMutableData()
        #if canImport(UniformTypeIdentifiers)
        let utType = UTType.png.identifier as CFString
        #else
        let utType = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, utType, 1, nil
        ) else {
            throw SnapshotError.pngEncodeFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.pngEncodeFailed
        }
        return data as Data
    }

    // MARK: - Comparison

    private static func compareBitmaps(
        _ actual: RGBABitmap, _ baseline: RGBABitmap
    ) -> DiffReport {
        var maxDrift: Double = 0
        var totalDrift: Double = 0
        var count: Double = 0
        var peakX = 0
        var peakY = 0
        var peakC = 0

        for y in 0..<actual.height {
            for x in 0..<actual.width {
                for c in 0..<3 {  // RGB only — alpha is by-filter-policy
                    let offset = (y * actual.width + x) * 4 + c
                    let a = Double(actual.bytes[offset]) / 255
                    let b = Double(baseline.bytes[offset]) / 255
                    let diff = abs(a - b)
                    totalDrift += diff
                    count += 1
                    if diff > maxDrift {
                        maxDrift = diff
                        peakX = x
                        peakY = y
                        peakC = c
                    }
                }
            }
        }

        return DiffReport(
            maxChannelDrift: maxDrift,
            meanChannelDrift: count > 0 ? totalDrift / count : 0,
            peakPixel: (peakX, peakY),
            peakChannel: peakC
        )
    }

    // MARK: - Metal plumbing

    private static func makeStagingTexture(
        like texture: MTLTexture
    ) throws -> MTLTexture {
        guard let device = Device.tryShared?.metalDevice else {
            throw SnapshotError.metalDeviceUnavailable
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width, height: texture.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let staging = device.makeTexture(descriptor: desc) else {
            throw SnapshotError.stagingTextureFailed
        }
        return staging
    }

    private static func blitCopy(
        from source: MTLTexture, to destination: MTLTexture
    ) throws {
        guard let device = Device.tryShared?.metalDevice,
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw SnapshotError.metalDeviceUnavailable
        }
        try BlitDispatcher.copy(
            source: source,
            destination: destination,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Errors

    enum SnapshotError: Error, CustomStringConvertible {
        case metalDeviceUnavailable
        case stagingTextureFailed
        case unsupportedPixelFormat(MTLPixelFormat)
        case pngEncodeFailed
        case pngDecodeFailed
        case bitmapContextFailed

        var description: String {
            switch self {
            case .metalDeviceUnavailable:
                return "Metal device unavailable for snapshot readback"
            case .stagingTextureFailed:
                return "Failed to create staging texture for snapshot readback"
            case .unsupportedPixelFormat(let f):
                return "Unsupported pixel format for snapshot: \(f)"
            case .pngEncodeFailed:
                return "PNG encoding failed"
            case .pngDecodeFailed:
                return "PNG decoding failed"
            case .bitmapContextFailed:
                return "CGBitmapContext creation failed"
            }
        }
    }
}
