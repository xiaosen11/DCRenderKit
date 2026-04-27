//
//  MultiPipelineStatusView.swift
//  DCRDemo
//
//  Debug HUD listing every active `Pipeline` in the demo with its
//  resource utilisation. Demonstrates the multi-Pipeline isolation
//  pattern visually — when you switch between camera and editor
//  tabs, you can see two distinct Pipelines coexist with their own
//  texture pools and PSO caches.
//
//  Toggleable from the Debug Menu (gear icon in the root tab bar).
//

import SwiftUI
import DCRenderKit

struct MultiPipelineStatusView: View {

    @Bindable var registry: DemoPipelineRegistry
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Active Pipelines (\(registry.entries.count))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))

                if registry.entries.isEmpty {
                    Text("No Pipeline active. Open Camera or Editor tab.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 8)
                } else {
                    ForEach(registry.entries) { snap in
                        PipelineStatusCard(snap: snap)
                    }
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .onReceive(timer) { _ in
            registry.tick()
        }
    }
}

private struct PipelineStatusCard: View {

    let snap: DemoPipelineRegistry.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snap.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            row(
                label: "Texture",
                value: "\(formatMB(snap.textureBytesCached)) / \(snap.textureCachedCount) tex"
            )
            row(
                label: "Uniforms",
                value: "\(snap.uniformSlotsInUse) / \(snap.uniformSlotsReserved) slots"
            )
            row(
                label: "PSO",
                value: "compute=\(snap.uberComputePSOCount) render=\(snap.uberRenderPSOCount)"
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func row(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.white.opacity(0.6))
            Text(value)
                .foregroundStyle(.white.opacity(0.95))
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func formatMB(_ bytes: Int) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb < 1.0 {
            return String(format: "%.0f KiB", Double(bytes) / 1024.0)
        }
        return String(format: "%.1f MiB", mb)
    }
}
