//
//  MetalImagePreview.swift
//  DCRDemo
//
//  MTKView-backed preview for a single still image. Renders on demand:
//  the MTKView is paused, and redraws are triggered by
//  `withObservationTracking` callbacks whenever any parameter on the
//  bound `EditParameters` changes, or whenever the source texture
//  swaps (sample-image switch). Idle GPU cost is zero.
//

import SwiftUI
import MetalKit
import Observation
import DCRenderKit

struct MetalImagePreview: UIViewRepresentable {

    @Bindable var params: EditParameters
    let metrics: PerformanceMetrics
    let sourceTexture: MTLTexture?
    /// Vision-generated subject mask for `PortraitBlurFilter`. `nil`
    /// means either "mask generation still in flight" or "no subject
    /// detected"; in both cases `FilterChainBuilder` excludes
    /// PortraitBlur from the chain.
    let portraitMask: MTLTexture?
    let device: MTLDevice
    /// Called on every drawn frame with the current view width in points.
    /// Used by callers (e.g. `PhotoEditModel`) to track the edit view
    /// width so that export can compute the same `pixelsPerPoint` ratio
    /// as the live preview.
    var onViewWidthChanged: ((Float) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device, metrics: metrics)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        // Derives from `DCRenderKit.defaultColorSpace`:
        //   .perceptual → .bgra8Unorm  (bytes flow unchanged, DigiCam parity)
        //   .linear     → .bgra8Unorm_srgb (GPU gamma-encodes on write)
        view.colorPixelFormat = DCRenderKit.defaultColorSpace.recommendedDrawablePixelFormat
        view.framebufferOnly = false
        view.delegate = context.coordinator
        // Paused render. A redraw fires only when:
        //  - a parameter on `params` mutates (Observation callback),
        //  - the sample image changes (updateUIView below), or
        //  - the drawable size changes (autoResizeDrawable).
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.bind(
            params: params,
            sourceTexture: sourceTexture,
            portraitMask: portraitMask,
            onViewWidthChanged: onViewWidthChanged
        )
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.cancelObservation()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {

        weak var view: MTKView?
        let device: MTLDevice
        let metrics: PerformanceMetrics

        private var params: EditParameters?
        private var sourceTexture: MTLTexture?
        private var portraitMask: MTLTexture?
        private var onViewWidthChanged: ((Float) -> Void)?
        private let commandQueue: MTLCommandQueue

        /// Long-lived `Pipeline` shared across every preview frame.
        /// Replacing this with per-frame construction would wipe
        /// the `CompiledChainCache` and reintroduce the
        /// Optimizer-per-frame CPU cost (Phase 11 root cause).
        ///
        /// Uses `Pipeline.makeIsolated(...)` so the editor's bursty
        /// allocations (4K source × multi-pass intermediates) don't
        /// starve a coexisting camera Pipeline in another tab.
        ///
        /// Budget rationale (full-res photo editing, up to 4K):
        /// - 64 MiB texture pool: 4K rgba16Float frame ≈ 32 MiB; this
        ///   covers source + a few multi-pass intermediates that
        ///   alias-overlap (HighlightShadow's 5-pass guided graph
        ///   peaks at ~3 live intermediates after aliasing)
        /// - 2 in-flight CBs: editing is interactive but slider drags
        ///   don't need 3-deep pipelining — 2 keeps GPU busy without
        ///   stale-frame queueing
        /// - 6 uniform slots: rapid slider drags update 4-6 filter
        ///   uniforms per frame; 6 avoids fence-block waits
        private let pipeline = Pipeline.makeIsolated(
            textureBudgetMB: 64,
            maxInFlightCommandBuffers: 2,
            uniformPoolCapacity: 6
        )

        /// Set to `true` when the coordinator has been dismantled; stops
        /// the observation loop from re-registering after that point.
        private var cancelled = false

        /// Token returned by `DemoPipelineRegistry.register(_:label:)`,
        /// used to drop the registry slot in `deinit`.
        private let registryID: Int

        init(device: MTLDevice, metrics: PerformanceMetrics) {
            self.device = device
            self.metrics = metrics
            self.commandQueue = device.makeCommandQueue()!
            self.registryID = DemoPipelineRegistry.shared.register(
                self.pipeline, label: "Editor"
            )
            super.init()
        }

        deinit {
            DemoPipelineRegistry.shared.unregister(id: registryID)
        }

        /// Called by `updateUIView` whenever SwiftUI hands new values
        /// (most often: a different `EditParameters` instance after a
        /// sample-image switch). Refreshes the coordinator's refs,
        /// triggers an immediate redraw, and re-arms the observation
        /// callback against the new `params` identity.
        @MainActor
        func bind(
            params: EditParameters,
            sourceTexture: MTLTexture?,
            portraitMask: MTLTexture?,
            onViewWidthChanged: ((Float) -> Void)?
        ) {
            self.params = params
            self.sourceTexture = sourceTexture
            self.portraitMask = portraitMask
            self.onViewWidthChanged = onViewWidthChanged
            view?.setNeedsDisplay()
            registerObservation()
        }

        func cancelObservation() {
            cancelled = true
        }

        /// Arm a one-shot `withObservationTracking` that fires the
        /// first time any observed property changes, then re-arms
        /// itself so subsequent changes continue to trigger redraws.
        ///
        /// Why one-shot re-registration: `withObservationTracking`
        /// fires its `onChange` exactly once per registration. Metal
        /// image-processing apps often need continuous observation, so
        /// the idiomatic pattern is to re-register from inside
        /// `onChange` — the tracking runtime makes this cheap.
        @MainActor
        private func registerObservation() {
            guard !cancelled, let params else { return }
            // Read the fingerprint inside the tracking closure. The
            // getter touches every stored @Observable property on the
            // instance, so any slider / LUT preset change triggers
            // `onChange` below.
            withObservationTracking {
                _ = params.fingerprint
            } onChange: { [weak self] in
                // `onChange` can fire on an unspecified thread. Hop to
                // main, setNeedsDisplay, then re-arm tracking.
                DispatchQueue.main.async {
                    guard let self, !self.cancelled else { return }
                    self.view?.setNeedsDisplay()
                    self.registerObservation()
                }
            }
        }

        // MARK: - MTKViewDelegate

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                drawOnMain(in: view)
            }
        }

        @MainActor
        private func drawOnMain(in view: MTKView) {
            guard
                let params,
                let source = sourceTexture,
                let drawable = view.currentDrawable,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            let viewWidthPt = max(Float(view.bounds.width), 1)
            let pixelsPerPoint = Float(source.width) / viewWidthPt
            onViewWidthChanged?(viewWidthPt)

            let chain = FilterChainBuilder.build(
                from: params,
                lumaMean: 0.5,
                pixelsPerPoint: pixelsPerPoint,
                portraitMask: portraitMask
            )
            metrics.chainLength = chain.count

            do {
                try pipeline.encode(
                    into: commandBuffer,
                    source: source,
                    steps: chain,
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
