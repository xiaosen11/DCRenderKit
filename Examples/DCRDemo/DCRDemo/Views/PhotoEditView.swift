//
//  PhotoEditView.swift
//  DCRDemo
//
//  Photo edit page. Sample image picker on top, live MTKView preview
//  showing the 24-slider-driven chain, slider panel at bottom, and an
//  "export to Photos" button with timing readout.
//
//  Parameters are per-image: each sample image keeps its own slider
//  state via `PhotoEditModel.currentParams`, so switching between
//  photos swaps the entire look.
//

import SwiftUI
import Metal
import DCRenderKit

struct PhotoEditView: View {

    @Bindable var editModel: PhotoEditModel
    let metrics: PerformanceMetrics
    let device: MTLDevice

    var body: some View {
        let params = editModel.currentParams

        return VStack(spacing: 0) {
            samplePickerBar
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))

            previewRegion(params: params)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .background(Color.black)

            EffectSlidersPanel(params: params)
        }
        .background(Color.black)
    }

    private var samplePickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SampleImage.all) { sample in
                    Button {
                        editModel.selectedImage = sample
                    } label: {
                        Text(sample.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                editModel.selectedImage == sample
                                    ? Color.orange
                                    : Color.gray.opacity(0.25)
                            )
                            .foregroundStyle(
                                editModel.selectedImage == sample
                                    ? Color.black
                                    : Color.white
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func previewRegion(params: EditParameters) -> some View {

        ZStack(alignment: .topLeading) {
            MetalImagePreview(
                params: params,
                metrics: metrics,
                sourceTexture: editModel.sourceTexture,
                device: device
            )

            PerformanceHUD(metrics: metrics)
                .padding(12)

            VStack {
                Spacer()
                HStack {
                    Button {
                        params.reset()
                    } label: {
                        Text("重置")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.55))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    exportButton
                }
                .padding(12)
            }
        }
    }

    private var exportButton: some View {
        Button {
            Task { await editModel.export() }
        } label: {
            HStack(spacing: 6) {
                if case .exporting = editModel.exportState {
                    ProgressView().tint(.black)
                }
                Text(exportLabel)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange)
            .foregroundStyle(.black)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(editModel.exportState == .exporting)
    }

    private var exportLabel: String {
        switch editModel.exportState {
        case .idle:
            return "导出到相册"
        case .exporting:
            return "导出中…"
        case .success(let ms):
            return String(format: "导出完成 %.0f ms", ms)
        case .failed:
            return "导出失败"
        }
    }
}
