//
//  DCRDemoApp.swift
//  DCRDemo
//
//  DCRenderKit demo app — exercises the SDK across camera preview
//  and photo edit + export, driven by 24 effect sliders aligned with
//  DigiCam's effect test page.
//

import SwiftUI
import Metal

@main
struct DCRDemoApp: App {

    private let device: MTLDevice

    init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("DCRDemo requires a Metal-capable device.")
        }
        self.device = metalDevice
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(device: device)
        }
    }
}
