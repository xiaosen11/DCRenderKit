//
//  RootTabView.swift
//  DCRDemo
//
//  App-level tab host. Two tabs: Camera preview / Photo edit.
//  Shared EditParameters + PerformanceMetrics so switching tabs keeps
//  the current look.
//

import SwiftUI
import Metal

struct RootTabView: View {

    @State private var params = EditParameters()
    @State private var metrics = PerformanceMetrics()
    @State private var editModel: PhotoEditModel

    let device: MTLDevice

    init(device: MTLDevice) {
        self.device = device
        _editModel = State(initialValue: PhotoEditModel(device: device))
    }

    var body: some View {
        TabView {
            Tab("相机", systemImage: "camera.fill") {
                CameraView(
                    params: params,
                    metrics: metrics,
                    device: device
                )
            }
            Tab("照片", systemImage: "photo.fill") {
                PhotoEditView(
                    params: params,
                    editModel: editModel,
                    metrics: metrics,
                    device: device
                )
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: params.lutPreset) { _, _ in
            metrics.reset()
        }
    }
}
