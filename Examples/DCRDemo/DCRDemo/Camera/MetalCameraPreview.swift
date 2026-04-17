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
        view.colorPixelFormat = .bgra8Unorm
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

        /// Camera-queue callback. Lock-synchronized write, then hop
        /// to main and ask MTKView to redraw.
        private func storeFrame(_ frame: CameraFrame) {
            frameLock.lock()
            latestFrame = frame
            frameLock.unlock()
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
                pixelsPerPoint: Float(view.window?.screen.scale ?? 3.0)
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
