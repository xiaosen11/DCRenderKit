//
//  CameraView.swift
//  DCRDemo
//
//  Camera preview page. 3:4 MTKView on top, slider panel on bottom,
//  performance HUD overlaid in the top-leading corner. Handles the
//  permission prompt on first launch and pauses capture when the tab
//  isn't visible (TabView keeps child views alive, so onDisappear
//  alone doesn't free the camera session).
//

import SwiftUI
import AVFoundation
import Metal
import DCRenderKit

struct CameraView: View {

    @Bindable var params: EditParameters
    let metrics: PerformanceMetrics
    let device: MTLDevice

    /// Passed down from `RootTabView`; `true` only when the camera
    /// tab is the selected tab. Drives start / stop of the capture
    /// session so we don't burn GPU + battery on the background tab.
    let isActive: Bool

    @State private var authorizationStatus: AVAuthorizationStatus =
        CameraController.currentAuthorizationStatus()
    @State private var cameraController: CameraController?

    var body: some View {
        VStack(spacing: 0) {
            previewRegion
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .background(Color.black)

            EffectSlidersPanel(params: params)
        }
        .background(Color.black)
        .task {
            await ensureAuthorizationAndStart()
        }
        .onChange(of: isActive) { _, nowActive in
            if nowActive {
                cameraController?.start()
                metrics.reset()
            } else {
                cameraController?.stop()
            }
        }
        .onDisappear {
            cameraController?.stop()
        }
    }

    @ViewBuilder
    private var previewRegion: some View {
        ZStack(alignment: .topLeading) {
            switch authorizationStatus {
            case .authorized:
                if let controller = cameraController {
                    MetalCameraPreview(
                        params: params,
                        metrics: metrics,
                        cameraController: controller,
                        device: device
                    )
                } else {
                    ProgressView().tint(.white)
                }
            case .notDetermined:
                ProgressView().tint(.white)
            default:
                permissionDeniedBanner
            }

            PerformanceHUD(metrics: metrics)
                .padding(12)

            Button {
                params.reset()
            } label: {
                Text("重置")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.55))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(12)
        }
    }

    private var permissionDeniedBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
            Text("需要相机权限")
                .font(.headline)
            Text("前往 设置 → 隐私与安全 → 相机 开启")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ensureAuthorizationAndStart() async {
        let granted = await CameraController.requestAuthorization()
        authorizationStatus = CameraController.currentAuthorizationStatus()
        guard granted else { return }
        if cameraController == nil {
            cameraController = CameraController(device: device)
        }
        // Only start if this tab is actually visible — otherwise the
        // onChange handler will start it later when the user navigates
        // to the camera tab.
        if isActive {
            cameraController?.start()
        }
    }
}
