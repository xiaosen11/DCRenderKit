//
//  MetalCameraPreview.swift
//  DCRDemo
//
//  MTKView-backed SwiftUI view that drives the DCRenderKit Pipeline
//  with camera frames delivered by CameraController. Renders the
//  filtered output directly to the drawable — zero intermediate copies
//  from camera frame to screen.
//

import SwiftUI
import MetalKit
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
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Parameters are read at render time through the captured reference.
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {

        weak var view: MTKView?

        let device: MTLDevice
        let params: EditParameters
        let metrics: PerformanceMetrics
        let cameraController: CameraController

        private let commandQueue: MTLCommandQueue

        // Latest frame lands here from the camera queue; the MTKView
        // drain picks it up on the next display tick. Lock-guarded so
        // the two threads can't race.
        private let frameLock = NSLock()
        private var latestFrame: CameraFrame?

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

        // Camera-queue callback. No actor isolation; lock-synchronized
        // write to `latestFrame`.
        private func storeFrame(_ frame: CameraFrame) {
            frameLock.lock()
            latestFrame = frame
            frameLock.unlock()
        }

        // MARK: - MTKViewDelegate

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // No special handling — autoResizeDrawable == true.
        }

        nonisolated func draw(in view: MTKView) {
            // MTKViewDelegate.draw is documented as main-thread; assume
            // main actor isolation so we can touch `@MainActor` state
            // (params, metrics) without bouncing through sync dispatch.
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
                // SDK bridges format (rgba16Float → bgra8Unorm) and size
                // from chain output to the drawable in one call.
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
