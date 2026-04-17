//
//  EffectSlidersPanel.swift
//  DCRDemo
//
//  The 24 slider list + LUT preset chips panel. Shared between the
//  camera preview page and the photo edit page so "tuning the look" is
//  an identical UX in both contexts.
//

import SwiftUI

struct EffectSlidersPanel: View {

    @Bindable var params: EditParameters

    var body: some View {
        VStack(spacing: 0) {
            lutPresetBar
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.5))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(EditParameters.definitions) { def in
                        SliderRow(def: def, params: params)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color.black.opacity(0.85))
        }
    }

    private var lutPresetBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LUTPreset.allCases) { preset in
                    Button {
                        params.lutPreset = preset
                    } label: {
                        Text(preset.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                params.lutPreset == preset
                                    ? Color.orange
                                    : Color.gray.opacity(0.25)
                            )
                            .foregroundStyle(
                                params.lutPreset == preset ? Color.black : Color.white
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct SliderRow: View {

    let def: EditParameters.Definition
    @Bindable var params: EditParameters

    private var value: Float {
        params[keyPath: def.keyPath]
    }

    private var binding: Binding<Float> {
        Binding(
            get: { params[keyPath: def.keyPath] },
            set: { params[keyPath: def.keyPath] = $0 }
        )
    }

    private var isAtDefault: Bool {
        abs(value - def.defaultValue) < 0.01
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(def.label)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 150, alignment: .leading)

            Slider(value: binding, in: def.min...def.max)
                .tint(isAtDefault ? .gray : .orange)

            Text(String(format: "%.0f", value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-tap resets to default.
            params[keyPath: def.keyPath] = def.defaultValue
        }
    }
}
