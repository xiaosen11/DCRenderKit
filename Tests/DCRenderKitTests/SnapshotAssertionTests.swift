//
//  SnapshotAssertionTests.swift
//  DCRenderKitTests
//
//  Self-tests for the snapshot-regression harness. Uses a temp
//  directory for baselines so the run has no footprint in the
//  source tree.
//

import XCTest
@testable import DCRenderKit
import Metal

final class SnapshotAssertionTests: XCTestCase {

    var tempDir: URL!

    override func setUpWithError() throws {
        guard Device.tryShared != nil else {
            throw XCTSkip("Metal device required")
        }
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DCRSnapshotSelfTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - Baseline roundtrip

    /// First call with a missing baseline must write the file and
    /// skip; a second call with the same content must pass.
    func testMissingBaselineSavesAndSkips() throws {
        let texture = try makeGreyTexture(value: 0.5)

        // First call: expect XCTSkip.
        var skipped = false
        do {
            try SnapshotAssertion.assertMatchesBaseline(
                texture,
                named: "grey_0_5",
                maxChannelDrift: 0.02,
                snapshotsDirectory: tempDir
            )
            XCTFail("First call should have thrown XCTSkip")
        } catch is XCTSkip {
            skipped = true
        }
        XCTAssertTrue(skipped, "Missing baseline must throw XCTSkip")

        let baselineURL = tempDir.appendingPathComponent("grey_0_5.png")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: baselineURL.path),
            "Baseline PNG must be saved on first run"
        )

        // Second call with same texture: must pass.
        try SnapshotAssertion.assertMatchesBaseline(
            texture,
            named: "grey_0_5",
            maxChannelDrift: 0.02,
            snapshotsDirectory: tempDir
        )
    }

    // MARK: - Drift detection

    /// A pixel difference inside the tolerance must pass.
    func testWithinToleranceDriftPasses() throws {
        let baseline = try makeGreyTexture(value: 0.5)
        // Save baseline.
        try? SnapshotAssertion.assertMatchesBaseline(
            baseline,
            named: "grey_tolerance",
            snapshotsDirectory: tempDir
        )
        // Small drift: 0.005 (≈ 1/255 step).
        let nudged = try makeGreyTexture(value: 0.505)
        try SnapshotAssertion.assertMatchesBaseline(
            nudged,
            named: "grey_tolerance",
            maxChannelDrift: 0.02,
            snapshotsDirectory: tempDir
        )
    }

    /// A pixel difference outside the tolerance must fail (via
    /// XCTFail — captured by expectFailure).
    func testBeyondToleranceDriftFails() throws {
        let baseline = try makeGreyTexture(value: 0.3)
        try? SnapshotAssertion.assertMatchesBaseline(
            baseline,
            named: "grey_drift_fail",
            snapshotsDirectory: tempDir
        )
        let drifted = try makeGreyTexture(value: 0.5)  // Δ = 0.2, huge.
        XCTExpectFailure("expected to fail because grey drifted ~20 %")
        try SnapshotAssertion.assertMatchesBaseline(
            drifted,
            named: "grey_drift_fail",
            maxChannelDrift: 0.02,
            snapshotsDirectory: tempDir
        )
    }

    // MARK: - Pixel-format coverage

    func testRGBA16FloatSnapshotWorks() throws {
        let tex = try makeGreyTexture(value: 0.25, pixelFormat: .rgba16Float)
        try? SnapshotAssertion.assertMatchesBaseline(
            tex,
            named: "rgba16f_snapshot",
            snapshotsDirectory: tempDir
        )
        // Re-run to assert.
        try SnapshotAssertion.assertMatchesBaseline(
            tex,
            named: "rgba16f_snapshot",
            maxChannelDrift: 0.01,
            snapshotsDirectory: tempDir
        )
    }

    func testRGBA8UnormSnapshotWorks() throws {
        let tex = try makeGreyTexture(value: 0.75, pixelFormat: .rgba8Unorm)
        try? SnapshotAssertion.assertMatchesBaseline(
            tex,
            named: "rgba8_snapshot",
            snapshotsDirectory: tempDir
        )
        try SnapshotAssertion.assertMatchesBaseline(
            tex,
            named: "rgba8_snapshot",
            maxChannelDrift: 0.01,
            snapshotsDirectory: tempDir
        )
    }

    // MARK: - Size mismatch

    func testSizeMismatchFails() throws {
        let small = try makeGreyTexture(value: 0.5, width: 4, height: 4)
        try? SnapshotAssertion.assertMatchesBaseline(
            small,
            named: "size_mismatch",
            snapshotsDirectory: tempDir
        )
        let big = try makeGreyTexture(value: 0.5, width: 16, height: 16)
        XCTExpectFailure("expected fail — baseline is 4×4 but candidate is 16×16")
        try SnapshotAssertion.assertMatchesBaseline(
            big,
            named: "size_mismatch",
            maxChannelDrift: 0.02,
            snapshotsDirectory: tempDir
        )
    }

    // MARK: - Helpers

    private func makeGreyTexture(
        value: Float,
        width: Int = 8,
        height: Int = 8,
        pixelFormat: MTLPixelFormat = .rgba16Float
    ) throws -> MTLTexture {
        guard let device = Device.tryShared?.metalDevice else {
            throw XCTSkip("Metal device required")
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))

        switch pixelFormat {
        case .rgba16Float:
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
        case .rgba8Unorm, .rgba8Unorm_srgb:
            let v = UInt8(max(0, min(255, (value * 255).rounded())))
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                pixels[i * 4 + 0] = v
                pixels[i * 4 + 1] = v
                pixels[i * 4 + 2] = v
                pixels[i * 4 + 3] = 255
            }
            pixels.withUnsafeBytes { bytes in
                tex.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: bytes.baseAddress!,
                    bytesPerRow: width * 4
                )
            }
        default:
            throw XCTSkip("Unsupported test texture format \(pixelFormat)")
        }
        return tex
    }
}
