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
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.params = params
        context.coordinator.sourceTexture = sourceTexture
        uiView.setNeedsDisplay()
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
                let output = try pipeline.encode(into: commandBuffer)
                guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
                let w = min(output.width, drawable.texture.width)
                let h = min(output.height, drawable.texture.height)
                blit.copy(
                    from: output, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: w, height: h, depth: 1),
                    to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()

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
