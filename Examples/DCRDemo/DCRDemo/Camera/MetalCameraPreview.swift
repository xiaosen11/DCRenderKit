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
        // ProMotion-capable devices default the display refresh rate
        // to 120Hz. Camera preview is bottlenecked at the camera
        // delivery rate (~30 fps), so allowing the display to redraw
        // faster only burns CPU on duplicate frames. Pin to 30 to
        // match the camera cadence.
        view.preferredFramesPerSecond = 30
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

        /// Long-lived `Pipeline` shared across every camera frame.
        /// Replacing this with per-frame construction would wipe
        /// the `CompiledChainCache` and reintroduce the
        /// Optimizer-per-frame CPU cost (Phase 11 root cause).
        ///
        /// Uses `Pipeline.makeIsolated(...)` so the camera path's
        /// resource pools (texture / command buffer / uniform) are
        /// independent of the photo-edit Pipeline running in another
        /// tab. Without isolation, the editor's bursty 4K-multi-pass
        /// allocations would starve the camera's 30fps preview.
        ///
        /// Budget rationale (camera preview, ≤ 1080p source):
        /// - 16 MiB texture pool: ~6 BGRA8 1080p frames cached
        /// - 3 in-flight CBs: 30fps double-buffering + safety margin
        /// - 4 uniform slots: enough for a typical preview chain
        ///   (Exposure / Contrast / Saturation / WhiteBalance) all
        ///   updating per-frame
        private let pipeline = Pipeline.makeIsolated(
            textureBudgetMB: 16,
            maxInFlightCommandBuffers: 3,
            uniformPoolCapacity: 4
        )

        // MARK: - Lightweight per-frame profiling
        // Accumulates wall-clock for each phase of `performRender`
        // and prints a one-line breakdown every 60 frames. Cheap
        // enough to leave on; remove once perf is dialled in.
        private var profCount = 0
        private var profTotalNs: UInt64 = 0
        private var profDrawableWaitNs: UInt64 = 0   // currentDrawable block (vsync / GPU back-pressure)
        private var profChainBuildNs: UInt64 = 0
        private var profEncodeNs: UInt64 = 0
        private var profCommitNs: UInt64 = 0
        private var profMaxTotalNs: UInt64 = 0

        // Latest camera frame lands here from the camera queue.
        private let frameLock = NSLock()
        private var latestFrame: CameraFrame?

        /// Throttled Vision mask cache for `PortraitBlurFilter`. Runs
        /// Vision on a background queue at ~500 ms cadence regardless
        /// of camera FPS, so portrait blur can track a moving subject
        /// without dragging preview frame delivery below 30 fps.
        private let maskCache = CameraPortraitMaskCache()

        /// Camera-queue-readable mirror of `params.portraitBlurStrength > 0`.
        /// Updated on main when params change (via the observation
        /// callback). Gates the per-frame Vision mask request so we
        /// never burn ~50ms of neural-net work for a filter the user
        /// isn't using.
        private let maskGateLock = NSLock()
        private var portraitActive: Bool = false

        private var cancelled = false

        /// Token returned by `DemoPipelineRegistry.register(_:label:)`,
        /// used to drop the registry slot in `deinit`.
        private let registryID: Int

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
            self.registryID = DemoPipelineRegistry.shared.register(
                self.pipeline, label: "Camera"
            )
            super.init()

            cameraController.onFrame = { [weak self] frame in
                self?.storeFrame(frame)
            }
        }

        deinit {
            // Pipeline registration is weakly-held so cleanup isn't
            // strictly required, but explicit deregistration keeps
            // the HUD list tight rather than waiting for next tick.
            DemoPipelineRegistry.shared.unregister(id: registryID)
        }

        /// Camera-queue callback. Lock-synchronized write, opportunistic
        /// background mask refresh, then hop to main and ask MTKView to
        /// redraw.
        private func storeFrame(_ frame: CameraFrame) {
            frameLock.lock()
            latestFrame = frame
            frameLock.unlock()

            // Offer this frame's pixel buffer to the mask cache only
            // when PortraitBlur is active. When the slider is at zero
            // the chain excludes PortraitBlurFilter regardless of the
            // mask state, so running Vision is pure waste (~50 ms of
            // neural-net work per call).
            maskGateLock.lock()
            let shouldRequestMask = portraitActive
            maskGateLock.unlock()

            if shouldRequestMask {
                maskCache.updateIfStale(from: frame.pixelBuffer)
            }

            DispatchQueue.main.async { [weak self] in
                self?.view?.setNeedsDisplay()
            }
        }

        @MainActor
        func registerObservation() {
            guard !cancelled else { return }
            // Refresh the Vision-gate mirror once per registration —
            // catches the initial value plus every subsequent param
            // change (each `onChange` fire re-registers, which lands
            // here again).
            updatePortraitGate()
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

        /// Update the camera-queue-readable mirror of "is PortraitBlur
        /// active". Called from the observation callback so the gate
        /// flips synchronously with the slider.
        @MainActor
        private func updatePortraitGate() {
            let active = params.portraitBlurStrength > 0
            maskGateLock.lock()
            portraitActive = active
            maskGateLock.unlock()
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
            let t0 = mach_absolute_time()

            frameLock.lock()
            let frame = latestFrame
            frameLock.unlock()

            guard let frame else { return }

            // `currentDrawable` is a SYNCHRONOUS BLOCKING call — it waits
            // for the next free CAMetalDrawable. When the GPU is busy
            // (long chain) or the display is back-pressured, this can
            // stall the main thread for ms. We split it out as its own
            // bucket so we don't blame chain build / encode for vsync
            // wait.
            let tDrawableStart = mach_absolute_time()
            guard let drawable = view.currentDrawable else { return }
            let tAfterDrawable = mach_absolute_time()

            guard let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            // `pixelsPerPoint` is "how many source pixels map onto
            // 1 pt of on-screen view" — required so visual-texture
            // filters (Sharpen step, FilmGrain grainSize, CCD sharp
            // step) read the same pt-size on screen across capture
            // resolutions. The right formula is `source / view_pt`,
            // **not** `UIScreen.scale`. They happen to agree at
            // 1080p source on a 390 pt iPhone screen (3.0 ≈ 2.77),
            // but diverge sharply at 4K (3 vs 10.3) — so we use the
            // robust formula here, matching the editing-preview path.
            let viewWidthPt = max(Float(view.bounds.width), 1)
            let pixelsPerPoint = Float(frame.texture.width) / viewWidthPt

            let chain = FilterChainBuilder.build(
                from: params,
                lumaMean: 0.5,
                pixelsPerPoint: pixelsPerPoint,
                portraitMask: maskCache.currentMask
            )
            metrics.chainLength = chain.count

            let tAfterChain = mach_absolute_time()

            do {
                try pipeline.encode(
                    into: commandBuffer,
                    source: frame.texture,
                    steps: chain,
                    writingTo: drawable.texture
                )

                let tAfterEncode = mach_absolute_time()

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

                let tAfterCommit = mach_absolute_time()
                accumulateProfile(
                    t0: t0,
                    tDrawableStart: tDrawableStart,
                    tAfterDrawable: tAfterDrawable,
                    tAfterChain: tAfterChain,
                    tAfterEncode: tAfterEncode,
                    tAfterCommit: tAfterCommit,
                    chainLength: chain.count
                )
            } catch {
                commandBuffer.commit()
            }
        }

        @MainActor
        private func accumulateProfile(
            t0: UInt64,
            tDrawableStart: UInt64,
            tAfterDrawable: UInt64,
            tAfterChain: UInt64,
            tAfterEncode: UInt64,
            tAfterCommit: UInt64,
            chainLength: Int
        ) {
            let total = tAfterCommit - t0
            profTotalNs += machTimeToNs(total)
            profDrawableWaitNs += machTimeToNs(tAfterDrawable - tDrawableStart)
            profChainBuildNs += machTimeToNs(tAfterChain - tAfterDrawable)
            profEncodeNs += machTimeToNs(tAfterEncode - tAfterChain)
            profCommitNs += machTimeToNs(tAfterCommit - tAfterEncode)
            profMaxTotalNs = max(profMaxTotalNs, machTimeToNs(total))
            profCount += 1

            guard profCount >= 60 else { return }
            let n = Double(profCount)
            let avgTotalMs = Double(profTotalNs) / n / 1_000_000
            let avgDrawableMs = Double(profDrawableWaitNs) / n / 1_000_000
            let avgChainMs = Double(profChainBuildNs) / n / 1_000_000
            let avgEncodeMs = Double(profEncodeNs) / n / 1_000_000
            let avgCommitMs = Double(profCommitNs) / n / 1_000_000
            let maxTotalMs = Double(profMaxTotalNs) / 1_000_000

            print(String(format:
                "[CamPerf] chain=%d frames=%d  avg_total=%.2fms  " +
                "(drawableWait=%.2f chainBuild=%.2f encode=%.2f commit=%.2f)  max=%.2fms",
                chainLength, profCount,
                avgTotalMs, avgDrawableMs, avgChainMs, avgEncodeMs, avgCommitMs,
                maxTotalMs
            ))

            profCount = 0
            profTotalNs = 0
            profDrawableWaitNs = 0
            profChainBuildNs = 0
            profEncodeNs = 0
            profCommitNs = 0
            profMaxTotalNs = 0
        }
    }
}

// MARK: - mach_time helper

/// Lazily-initialised, never-mutated timebase. `mach_timebase_info_data_t`
/// is a pair of `UInt32`s — Sendable by nature.
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

private func machTimeToNs(_ ticks: UInt64) -> UInt64 {
    return ticks * UInt64(machTimebase.numer) / UInt64(machTimebase.denom)
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
