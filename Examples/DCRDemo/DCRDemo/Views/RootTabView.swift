//
//  RootTabView.swift
//  DCRDemo
//
//  App-level tab host. Two tabs: camera preview / photo edit.
//  EditParameters is shared between tabs (tuning the look carries
//  over); PerformanceMetrics is per-tab so the HUD reflects the
//  render loop of the page you're actually looking at.
//

import SwiftUI
import Metal

struct RootTabView: View {

    enum TabTag: Hashable { case camera, photo }

    /// Camera preview has its own parameter set. Edit params for a
    /// sample image live on the `PhotoEditModel` (keyed by image),
    /// so camera tuning is independent from any photo's tuning.
    @State private var cameraParams = EditParameters()
    @State private var cameraMetrics = PerformanceMetrics()
    @State private var photoMetrics = PerformanceMetrics()
    @State private var editModel: PhotoEditModel
    @State private var selectedTab: TabTag = .camera
    @State private var showPipelineHUD = false

    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        _editModel = State(initialValue: PhotoEditModel(device: device))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $selectedTab) {
                Tab("相机", systemImage: "camera.fill", value: TabTag.camera) {
                    CameraView(
                        params: cameraParams,
                        metrics: cameraMetrics,
                        device: device,
                        isActive: selectedTab == .camera
                    )
                }
                Tab("照片", systemImage: "photo.fill", value: TabTag.photo) {
                    PhotoEditView(
                        editModel: editModel,
                        metrics: photoMetrics,
                        device: device
                    )
                }
            }

            // Multi-Pipeline status overlay — toggle via the gear icon.
            // Demonstrates that camera + editor + export Pipelines run
            // with independent texture / CB / uniform budgets.
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    showPipelineHUD.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(
                            Circle().fill(Color.black.opacity(0.55))
                        )
                }
                .padding(.top, 60)
                .padding(.trailing, 12)

                if showPipelineHUD {
                    MultiPipelineStatusView(registry: DemoPipelineRegistry.shared)
                        .frame(width: 260)
                        .padding(.trailing, 12)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
