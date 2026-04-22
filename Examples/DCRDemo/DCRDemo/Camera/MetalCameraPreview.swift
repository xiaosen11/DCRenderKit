//
//  MetalCameraPreview.swift
//  DCRDemo
//
//  MTKView-backed SwiftUI view that drives the DCRenderKit Pipeline
//  with camera frames delivered by CameraController. The MTKView is
//  paused — redraws fire only when a new camera frame arrives OR a
//  parameter mutates. Idle GPU cost is zero; active redraw cadence
//  is the camera's natural frame rate (~30 fps) plus slider activity.
//

import SwiftUI
import MetalKit
import Observation
import QuartzCore
import DCRenderKit

struct MetalCameraPreview: UIViewRepresentable {

    @Bindable var params: EditParameters
    let metrics: PerformanceMetrics
    let cameraController: CameraController
    let device: MTLDevice

    func makeCoordinator() -> Coordinator {
        Coordinator(
            device: device,
            params: params,
            metrics: metrics,
            cameraController: cameraController
        )
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        // Derives from `DCRenderKit.defaultColorSpace`:
        //   .perceptual → .bgra8Unorm  (bytes flow unchanged, DigiCam parity)
        //   .linear     → .bgra8Unorm_srgb (GPU gamma-encodes on write)
        view.colorPixelFormat = DCRenderKit.defaultColorSpace.recommendedDrawablePixelFormat
        view.framebufferOnly = false
        view.delegate = context.coordinator
        // Paused MTKView: redraw only on demand. Two demand sources —
        // CameraController.onFrame for new camera data, and
        // Observation.withObservationTracking for slider mutations.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        context.coordinator.view = view
        context.coordinator.registerObservation()
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Nothing to push — the coordinator holds stable references
        // and the view only needs to redraw when frames / params
        // change, both handled internally.
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.cancelObservation()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {

        weak var view: MTKView?

        let device: MTLDevice
        let params: EditParameters
        let metrics: PerformanceMetrics
        let cameraController: CameraController

        private let commandQueue: MTLCommandQueue

        // Latest camera frame lands here from the camera queue.
        private let frameLock = NSLock()
        private var latestFrame: CameraFrame?

        /// Throttled Vision mask cache for `PortraitBlurFilter`. Runs
        /// Vision on a background queue at ~500 ms cadence regardless
        /// of camera FPS, so portrait blur can track a moving subject
        /// without dragging preview frame delivery below 30 fps.
        private let maskCache = CameraPortraitMaskCache()

        private var cancelled = false

        init(
            device: MTLDevice,
            params: EditParameters,
            metrics: PerformanceMetrics,
            cameraController: CameraController
        ) {
            self.device = device
            self.params = params
            self.metrics = metrics
            self.cameraController = cameraController
            self.commandQueue = device.makeCommandQueue()!
            super.init()

            cameraController.onFrame = { [weak self] frame in
                self?.storeFrame(frame)
            }
        }

        /// Camera-queue callback. Lock-synchronized write, opportunistic
        /// background mask refresh, then hop to main and ask MTKView to
        /// redraw.
        private func storeFrame(_ frame: CameraFrame) {
            frameLock.lock()
            latestFrame = frame
            frameLock.unlock()

            // Offer this frame's pixel buffer to the mask cache. Most
            // calls are rejected (throttle), which is cheap; the
            // accepted one kicks off a detached Vision run that
            // updates `maskCache.currentMask` whenever it finishes.
            maskCache.updateIfStale(from: frame.pixelBuffer)

            DispatchQueue.main.async { [weak self] in
                self?.view?.setNeedsDisplay()
            }
        }

        @MainActor
        func registerObservation() {
            guard !cancelled else { return }
            withObservationTracking {
                _ = params.fingerprint
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.cancelled else { return }
                    self.view?.setNeedsDisplay()
                    self.registerObservation()
                }
            }
        }

        func cancelObservation() {
            cancelled = true
        }

        // MARK: - MTKViewDelegate

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No special handling — autoResizeDrawable == true.
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                performRender(in: view)
            }
        }

        @MainActor
        private func performRender(in view: MTKView) {
            frameLock.lock()
            let frame = latestFrame
            frameLock.unlock()

            guard let frame,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            let chain = FilterChainBuilder.build(
                from: params,
                lumaMean: 0.5,
                pixelsPerPoint: Float(view.window?.screen.scale ?? 3.0),
                portraitMask: maskCache.currentMask
            )
            metrics.chainLength = chain.count

            let pipeline = Pipeline(input: .texture(frame.texture), steps: chain)

            do {
                try pipeline.encode(
                    into: commandBuffer,
                    writingTo: drawable.texture
                )

                let metricsRef = metrics
                commandBuffer.addCompletedHandler { buf in
                    let gpuTime = buf.gpuEndTime - buf.gpuStartTime
                    Task { @MainActor in
                        metricsRef.recordGPUTime(seconds: gpuTime)
                        metricsRef.recordFrame()
                    }
                }

                commandBuffer.present(drawable)
                commandBuffer.commit()
            } catch {
                commandBuffer.commit()
            }
        }
    }
}

// MARK: - CameraPortraitMaskCache

/// Background-refreshed Vision portrait-mask cache for the camera
/// preview. Vision's `VNGenerateForegroundInstanceMaskRequest` typically
/// runs in 200–500 ms per 1080p frame — far too slow to run on every
/// camera frame at 30 fps. We throttle to at most one concurrent Vision
/// pass and ignore requests that arrive within `refreshInterval` of the
/// last one starting, which keeps preview rendering decoupled from the
/// mask update cadence.
///
/// The mask always reflects *some* recent frame: on a static scene it
/// settles almost immediately; on a fast-changing scene it lags by
/// ~500 ms, which is an acceptable physical limit for a consumer demo.
/// When the cache has never produced a mask (first half-second of
/// preview, or Vision found no subject), `currentMask` is `nil` and
/// `FilterChainBuilder` excludes `PortraitBlurFilter` from the chain.
///
/// `@unchecked Sendable` because the internal mutable state is guarded
/// by an explicit lock — Swift 6 strict concurrency cannot verify this
/// invariant statically but the contract holds.
final class CameraPortraitMaskCache: @unchecked Sendable {

    /// Minimum time between Vision run *starts*. Not "between
    /// completions" — we start the clock on dispatch so the next
    /// throttle window opens on a predictable cadence instead of
    /// sliding with Vision run time.
    static let refreshInterval: TimeInterval = 0.5

    private let lock = NSLock()
    private var latestMask: MTLTexture?
    private var lastGenerationStart: TimeInterval = -.infinity
    private var isGenerating = false

    /// Last-known Vision mask. `nil` until the first successful
    /// generation lands, and whenever the most recent Vision run found
    /// no foreground subject.
    var currentMask: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latestMask
    }

    /// Offer a pixel buffer as the source for the next Vision run.
    /// Returns immediately; the caller is never blocked by Vision
    /// work. If the throttle window is still open or a previous run
    /// hasn't completed, the frame is simply dropped.
    func updateIfStale(from pixelBuffer: CVPixelBuffer) {
        lock.lock()
        let now = CACurrentMediaTime()
        let shouldRun = !isGenerating
            && (now - lastGenerationStart) >= Self.refreshInterval
        if shouldRun {
            lastGenerationStart = now
            isGenerating = true
        }
        lock.unlock()

        guard shouldRun else { return }

        let pixelBufferBox = CameraMaskPixelBufferBox(buffer: pixelBuffer)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let mask = PortraitBlurMaskGenerator.generate(
                from: pixelBufferBox.buffer
            )
            self.lock.lock()
            if let mask {
                self.latestMask = mask
            }
            self.isGenerating = false
            self.lock.unlock()
        }
    }
}

/// `@unchecked Sendable` wrapper so a `CVPixelBuffer` can be handed
/// into a background DispatchQueue closure under Swift 6 strict
/// concurrency. Core Video buffers are reference-counted CF objects
/// and safe to retain across threads; Vision only reads from them.
private struct CameraMaskPixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}
