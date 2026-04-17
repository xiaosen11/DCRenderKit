//
//  MetalImagePreview.swift
//  DCRDemo
//
//  MTKView-backed preview for a single still image. Re-renders on
//  every parameter change; the filter chain is lightweight so sub-
//  100ms latency is achievable even at 12MP.
//

import SwiftUI
import MetalKit
import DCRenderKit

struct MetalImagePreview: UIViewRepresentable {

    @Bindable var params: EditParameters
    let metrics: PerformanceMetrics
    let sourceTexture: MTLTexture?
    let device: MTLDevice

    func makeCoordinator() -> Coordinator {
        Coordinator(device: device, metrics: metrics)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.delegate = context.coordinator
        // Drive the preview at 30 fps continuously. Paused
        // (setNeedsDisplay-triggered) rendering is theoretically
        // cheaper but requires SwiftUI Observation to propagate
        // through the UIViewRepresentable boundary, which turned out
        // to be fragile across different view hierarchies. A constant
        // 30 fps loop reads params on every frame and always reflects
        // the latest slider value — slightly higher GPU idle cost
        // (~1–2 ms/frame doing nothing) in exchange for bulletproof
        // live response.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = true
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // Coordinator reads the latest params / sourceTexture on every
        // frame via captured references, so updateUIView's job is
        // simply to keep those references current whenever the parent
        // body hands us new values (e.g. after a sample-image switch).
        context.coordinator.params = params
        context.coordinator.sourceTexture = sourceTexture
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {

        weak var view: MTKView?
        let device: MTLDevice
        let metrics: PerformanceMetrics

        var params: EditParameters?
        var sourceTexture: MTLTexture?

        private let commandQueue: MTLCommandQueue

        init(device: MTLDevice, metrics: PerformanceMetrics) {
            self.device = device
            self.metrics = metrics
            self.commandQueue = device.makeCommandQueue()!
            super.init()
        }

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

            let pixelsPerPoint = Float(source.width) / max(Float(view.bounds.width), 1)

            let chain = FilterChainBuilder.build(
                from: params,
                lumaMean: 0.5,
                pixelsPerPoint: pixelsPerPoint
            )
            metrics.chainLength = chain.count

            let pipeline = Pipeline(input: .texture(source), steps: chain)

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
