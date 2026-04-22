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

/// `@unchecked Sendable` box so an `CGImage` can cross actor boundaries
/// into a detached Vision task. `CGImage` is thread-safe for read-only
/// use; we never mutate the image after it's loaded from the bundle.
private struct PortraitEditImageBox: @unchecked Sendable {
    let image: CGImage
}

/// `@unchecked Sendable` box so a Vision-generated `MTLTexture?` can
/// cross the actor boundary back to MainActor for publication.
/// `MTLTexture` is thread-safe for read after creation, and we treat
/// the mask as immutable (Vision builds a fresh texture each run).
private struct PortraitEditMaskBox: @unchecked Sendable {
    let mask: MTLTexture?
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

    /// Vision-generated foreground-subject mask for the current source.
    /// Regenerated asynchronously on every sample-image switch so that
    /// `PortraitBlurFilter` can activate the moment the user touches
    /// its slider. Tracked by `@Observable` so SwiftUI previews pick
    /// up nil → available transitions.
    ///
    /// `nil` means either "generation still in flight" (first ~0.5–1s
    /// after an image switch, Vision is CPU-heavy) OR "Vision detected
    /// no foreground subject". `FilterChainBuilder` treats both the
    /// same — PortraitBlur is excluded from the chain.
    private(set) var portraitMask: MTLTexture?

    /// In-flight mask-generation handle. Cancelled on sample-image
    /// switch so a slow Vision run on image A cannot clobber image B's
    /// mask after the user has moved on.
    private var maskTask: Task<Void, Never>?

    /// Export progress / result.
    private(set) var exportState: ExportState = .idle

    /// Most recent export duration in milliseconds. Displayed on the UI.
    private(set) var lastExportMs: Double = 0

    /// Per-image parameter sets. Each `SampleImage` keeps its own slider
    /// state so switching between images preserves whatever look the
    /// user was last tuning on that photo — matches how real editing
    /// apps feel. Eagerly initialized so that `currentParams` is a pure
    /// read; lazy init would have mutated this dictionary inside a
    /// SwiftUI body evaluation, which confuses Observation and breaks
    /// live slider response.
    private let paramsByImage: [String: EditParameters]

    /// The `EditParameters` instance bound to the currently-selected
    /// image. Guaranteed non-nil because `paramsByImage` was populated
    /// for every `SampleImage` at init time.
    var currentParams: EditParameters {
        paramsByImage[selectedImage.id] ?? EditParameters()
    }

    private let device: MTLDevice
    private let textureLoader: TextureLoader

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = TextureLoader(device: Device.shared)
        var initial: [String: EditParameters] = [:]
        for image in SampleImage.all {
            initial[image.id] = EditParameters()
        }
        self.paramsByImage = initial
        reloadSourceTexture()
    }

    private func reloadSourceTexture() {
        // Cancel any in-flight mask generation for a previous image
        // switch so a slow Vision run cannot clobber the current
        // image's mask after the user has moved on. Set to nil first
        // so that UI observers see "no mask yet" immediately.
        maskTask?.cancel()
        maskTask = nil
        portraitMask = nil

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

        // Kick off Vision mask generation for the new source. Detached
        // so the CPU-heavy Vision pass doesn't block the MainActor
        // while the user is dragging sliders immediately after a
        // sample-image switch. Result is hopped back via an isolated
        // helper — calling a MainActor method directly avoids the
        // `sending 'self' risks causing data races` error that Swift 6
        // strict concurrency raises when `self` is captured through a
        // detached closure into a nested MainActor.run.
        let imageBox = PortraitEditImageBox(image: cgImage)
        maskTask = Task.detached { [weak self] in
            let mask = PortraitBlurMaskGenerator.generate(
                from: imageBox.image
            )
            let maskBox = PortraitEditMaskBox(mask: mask)
            guard !Task.isCancelled else { return }
            await self?.applyPortraitMask(maskBox.mask)
        }
    }

    /// MainActor-isolated setter so the detached Vision task can
    /// publish its result without needing to thread `self` through a
    /// nested `MainActor.run` closure.
    @MainActor
    private func applyPortraitMask(_ mask: MTLTexture?) {
        portraitMask = mask
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
                pixelsPerPoint: Float(source.width) / 390.0,  // approximate for export context
                portraitMask: portraitMask
            )
            let pipeline = Pipeline(input: .texture(source), steps: chain)
            let output = try await pipeline.output()

            let dt = (CACurrentMediaTime() - start) * 1000
            lastExportMs = dt

            let image = try await Self.cgImageFromTexture(
                output,
                sourceColorSpace: DCRenderKit.defaultColorSpace
            )
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

    private static func cgImageFromTexture(
        _ texture: MTLTexture,
        sourceColorSpace: DCRColorSpace
    ) async throws -> CGImage {
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
        let needsGammaEncode = (sourceColorSpace == .linear)
        for i in 0..<(w * h) {
            var r = Float(Float16(bitPattern: half[i * 4 + 0]))
            var g = Float(Float16(bitPattern: half[i * 4 + 1]))
            var b = Float(Float16(bitPattern: half[i * 4 + 2]))
            let a = Float(Float16(bitPattern: half[i * 4 + 3]))
            r = max(0, min(1, r))
            g = max(0, min(1, g))
            b = max(0, min(1, b))
            // CGColorSpaceCreateDeviceRGB() is sRGB on iOS; it expects
            // gamma-encoded bytes. In `.linear` mode the pipeline output
            // carries linear-light values, so we must gamma-encode
            // before packing to UInt8. Skipping this step causes Photos
            // to decode the linear value as if it were sRGB-encoded and
            // darken midtones by roughly pow(0.5, 2.2) / 0.5 ≈ 2.3x.
            //
            // `pow(x, 1/2.2)` mirrors the SDK's internal linear↔perceptual
            // approximation; when findings-and-plan.md §8.1 A.1 swaps
            // the SDK to a piecewise sRGB curve, update this site in
            // lockstep to keep the round-trip symmetric.
            if needsGammaEncode {
                r = pow(r, 1.0 / 2.2)
                g = pow(g, 1.0 / 2.2)
                b = pow(b, 1.0 / 2.2)
            }
            u8[i * 4 + 0] = UInt8(r * 255)
            u8[i * 4 + 1] = UInt8(g * 255)
            u8[i * 4 + 2] = UInt8(b * 255)
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

        // Encode on the calling actor so the cross-actor hand-off only
        // carries a Sendable `Data` — `UIImage` is non-Sendable and would
        // otherwise leak MainActor isolation into the PhotoLibrary queue.
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpegData = uiImage.jpegData(compressionQuality: 0.95) else {
            throw NSError(
                domain: "DCRDemo.Export", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"]
            )
        }

        try await Self.persistJPEGToPhotos(jpegData: jpegData)
    }

    /// Persist a JPEG payload to the user's Photos library.
    ///
    /// `nonisolated` + `static` is load-bearing: `PhotoEditModel` is
    /// `@MainActor`-isolated, and a `performChanges` closure defined as
    /// an instance/static method on a MainActor type inherits MainActor
    /// isolation. PhotoLibrary then dispatches that closure onto its
    /// internal serial queue (`com.apple.PhotoLibrary.changes`) and
    /// trips a `dispatch_assert_queue` check inside
    /// `_performCancellableChanges`, crashing with `EXC_BREAKPOINT` on
    /// `_dispatch_assert_queue_fail`. Severing MainActor inheritance
    /// with `nonisolated` lets the closure run in the non-isolated
    /// concurrent domain that PhotoLibrary expects.
    ///
    /// We also use `addResource(with:data:options:)` rather than
    /// `creationRequestForAsset(from: UIImage)` so the closure captures
    /// only the trivially-`Sendable` `Data` — no `UIImage` crosses the
    /// actor boundary.
    private nonisolated static func persistJPEGToPhotos(
        jpegData: Data
    ) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: jpegData, options: nil)
        }
    }
}
