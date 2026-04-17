//
//  PerformanceMetrics.swift
//  DCRDemo
//
//  Rolling FPS and GPU-time tracker. Drives the overlay HUD. Updated
//  once per rendered frame from the camera / edit render callback.
//

import Foundation
import Metal
import Observation
import QuartzCore

@Observable
@MainActor
final class PerformanceMetrics {

    // MARK: - Published properties (drive the HUD)

    /// Rolling average frames-per-second over the last `windowSize`
    /// frames. `0` before the first two frames have been recorded.
    private(set) var fps: Double = 0

    /// Rolling average GPU time (milliseconds) spent rendering a frame,
    /// from Metal's `commandBuffer.gpuStartTime` / `gpuEndTime`. `0` if
    /// the renderer hasn't reported a value yet.
    private(set) var gpuMs: Double = 0

    /// Current length of the filter chain (number of single- or
    /// multi-pass filters). Cheap signal for "is this chain heavy".
    var chainLength: Int = 0

    // MARK: - Internal state

    private let windowSize = 30
    private var frameTimestamps: [CFTimeInterval] = []
    private var gpuTimes: [Double] = []

    // MARK: - Hooks called by the renderer

    /// Record the wall-clock timestamp of a completed frame.
    /// Call exactly once per `MTKView.draw` / edit render.
    func recordFrame() {
        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        if frameTimestamps.count > windowSize {
            frameTimestamps.removeFirst(frameTimestamps.count - windowSize)
        }
        guard frameTimestamps.count >= 2 else { return }
        let dt = frameTimestamps.last! - frameTimestamps.first!
        fps = dt > 0 ? Double(frameTimestamps.count - 1) / dt : 0
    }

    /// Record the GPU time of a completed command buffer.
    /// Use `commandBuffer.gpuEndTime - commandBuffer.gpuStartTime`.
    func recordGPUTime(seconds: Double) {
        let ms = seconds * 1000.0
        gpuTimes.append(ms)
        if gpuTimes.count > windowSize {
            gpuTimes.removeFirst(gpuTimes.count - windowSize)
        }
        gpuMs = gpuTimes.reduce(0, +) / Double(gpuTimes.count)
    }

    /// Reset the rolling window — useful when switching pages so stale
    /// numbers don't leak into a new context.
    func reset() {
        frameTimestamps.removeAll(keepingCapacity: true)
        gpuTimes.removeAll(keepingCapacity: true)
        fps = 0
        gpuMs = 0
    }
}
