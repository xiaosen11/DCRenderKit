//
//  PhotoEditModel.swift
//  DCRDemo
//
//  Photo-edit page view model. Owns the sample image selection, the
//  currently-resident source texture, and the async export flow.
//

import Foundation
import UIKit
import Metal
import Observation
import Photos
import DCRenderKit

/// One of the bundled sample images the user can pick for editing.
struct SampleImage: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let fileName: String   // without extension, under Resources/SampleImages/

    static let all: [SampleImage] = [
        .init(id: "portrait",     displayName: "人像",         fileName: "portrait"),
        .init(id: "castle_night", displayName: "城堡夜景",     fileName: "castle_night"),
        .init(id: "bridge",       displayName: "小桥户外景",   fileName: "bridge"),
        .init(id: "tower",        displayName: "铁塔建筑",     fileName: "tower"),
    ]
}

enum ExportState: Sendable, Equatable {
    case idle
    case exporting
    case success(durationMs: Double)
    case failed(message: String)
}

@Observable
@MainActor
final class PhotoEditModel {

    /// Current sample image (for preview rendering).
    var selectedImage: SampleImage = SampleImage.all[0] {
        didSet {
            if oldValue != selectedImage {
                reloadSourceTexture()
            }
        }
    }

    /// Loaded source texture. Nil before the first successful load.
    private(set) var sourceTexture: MTLTexture?

    /// Export progress / result.
    private(set) var exportState: ExportState = .idle

    /// Most recent export duration in milliseconds. Displayed on the UI.
    private(set) var lastExportMs: Double = 0

    /// Per-image parameter sets. Each `SampleImage` keeps its own slider
    /// state so switching between images preserves whatever look the
    /// user was last tuning on that photo — matches how real editing
    /// apps feel. Lazy-initialized on first access via `currentParams`.
    private var paramsByImage: [String: EditParameters] = [:]

    /// The `EditParameters` instance bound to the currently-selected
    /// image. Allocates a fresh set on first access for each image.
    var currentParams: EditParameters {
        if let existing = paramsByImage[selectedImage.id] {
            return existing
        }
        let fresh = EditParameters()
        paramsByImage[selectedImage.id] = fresh
        return fresh
    }

    private let device: MTLDevice
    private let textureLoader: TextureLoader

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = TextureLoader(device: Device.shared)
        reloadSourceTexture()
    }

    private func reloadSourceTexture() {
        // Resources land at bundle root (xcodegen auto-classifies files
        // under `sources:` and flattens them into the resources phase).
        guard let url = Bundle.main.url(
            forResource: selectedImage.fileName,
            withExtension: "jpg"
        ),
        let data = try? Data(contentsOf: url),
        let uiImage = UIImage(data: data),
        let cgImage = uiImage.cgImage
        else {
            sourceTexture = nil
            return
        }

        sourceTexture = try? textureLoader.makeTexture(from: cgImage)
    }

    // MARK: - Export

    /// Run the current filter chain against the source texture at
    /// full resolution and save the result to Photos. Uses the
    /// selected image's own parameter set — exporting one image
    /// doesn't require passing its parameters in.
    func export() async {
        guard case .idle = exportState else { return }
        guard let source = sourceTexture else { return }

        exportState = .exporting

        let start = CACurrentMediaTime()
        do {
            let chain = FilterChainBuilder.build(
                from: currentParams,
                lumaMean: 0.5,
                pixelsPerPoint: Float(source.width) / 390.0  // approximate for export context
            )
            let pipeline = Pipeline(input: .texture(source), steps: chain)
            let output = try await pipeline.output()

            let dt = (CACurrentMediaTime() - start) * 1000
            lastExportMs = dt

            let image = try await Self.cgImageFromTexture(output)
            try await saveToPhotos(cgImage: image)

            exportState = .success(durationMs: dt)

            // Auto-clear status after 3s so the UI can export again.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .success = exportState { exportState = .idle }
        } catch {
            exportState = .failed(message: String(describing: error))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .failed = exportState { exportState = .idle }
        }
    }

    // MARK: - Private helpers

    private static func cgImageFromTexture(_ texture: MTLTexture) async throws -> CGImage {
        // Read back rgba16Float pixels → convert to 8-bit for JPEG.
        let w = texture.width
        let h = texture.height

        // First, blit to a shared-storage staging texture if needed.
        let queue = Device.shared.metalDevice.makeCommandQueue()!
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let staging = Device.shared.metalDevice.makeTexture(descriptor: desc) else {
            throw NSError(domain: "DCRDemo.Export", code: 1)
        }
        let cb = queue.makeCommandBuffer()!
        try BlitDispatcher.copy(source: texture, destination: staging, commandBuffer: cb)
        // `waitUntilCompleted` is unavailable from async contexts under
        // Swift 6; bridge via a completion-handler continuation instead.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cb.addCompletedHandler { _ in continuation.resume() }
            cb.commit()
        }

        // rgba16Float → rgba8 conversion on CPU.
        var half = [UInt16](repeating: 0, count: w * h * 4)
        half.withUnsafeMutableBytes { bytes in
            staging.getBytes(
                bytes.baseAddress!,
                bytesPerRow: w * 8,
                from: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0
            )
        }
        var u8 = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let r = Float(Float16(bitPattern: half[i * 4 + 0]))
            let g = Float(Float16(bitPattern: half[i * 4 + 1]))
            let b = Float(Float16(bitPattern: half[i * 4 + 2]))
            let a = Float(Float16(bitPattern: half[i * 4 + 3]))
            u8[i * 4 + 0] = UInt8(max(0, min(1, r)) * 255)
            u8[i * 4 + 1] = UInt8(max(0, min(1, g)) * 255)
            u8[i * 4 + 2] = UInt8(max(0, min(1, b)) * 255)
            u8[i * 4 + 3] = UInt8(max(0, min(1, a)) * 255)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: &u8,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let cg = ctx.makeImage() else {
            throw NSError(domain: "DCRDemo.Export", code: 2)
        }
        return cg
    }

    private func saveToPhotos(cgImage: CGImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "DCRDemo.Export", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Photos permission denied"]
            )
        }
        let image = UIImage(cgImage: cgImage)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }
}
