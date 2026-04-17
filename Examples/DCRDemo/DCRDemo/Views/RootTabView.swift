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

    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        _editModel = State(initialValue: PhotoEditModel(device: device))
    }

    var body: some View {
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
        .preferredColorScheme(.dark)
    }
}
