//
//  PerformanceHUD.swift
//  DCRDemo
//
//  Overlay HUD that sits on top of the preview. Shows FPS / GPU ms /
//  chain length in monospaced digits. Non-interactive — just a read-out.
//

import SwiftUI

struct PerformanceHUD: View {

    let metrics: PerformanceMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            hudLine(label: "FPS",   value: String(format: "%.1f", metrics.fps))
            hudLine(label: "GPU",   value: String(format: "%.2f ms", metrics.gpuMs))
            hudLine(label: "Chain", value: "\(metrics.chainLength)")
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(fpsColor.opacity(0.6), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    /// Colour-code the FPS ring: green ≥ 50, amber 25–50, red < 25.
    /// Matches the 30fps / 15fps acceptance bands.
    private var fpsColor: Color {
        if metrics.fps >= 50 { return .green }
        if metrics.fps >= 25 { return .orange }
        return .red
    }

    private func hudLine(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, alignment: .leading)
            Text(value)
                .foregroundStyle(.white)
        }
    }
}
