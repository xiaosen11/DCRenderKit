//
//  CameraController.swift
//  DCRDemo
//
//  AVCaptureSession wrapper that delivers camera frames as MTLTexture
//  via CVMetalTextureCache (zero-copy, BGRA8Unorm). Not `@MainActor`:
//  the session runs on its own serial queue and the frame callback
//  fires on a background queue. SwiftUI code wraps this in an
//  `@Observable` view model for UI state.
//

import AVFoundation
import CoreVideo
import Metal

/// Per-frame payload. The texture is valid only until the next frame
/// replaces it; consumers must render before the next delivery.
struct CameraFrame: @unchecked Sendable {
    let texture: MTLTexture
    let presentationTime: CMTime
}

/// Plain (non-actor) session wrapper. All public methods are safe to
/// call from any thread; internal session mutation runs on a dedicated
/// serial queue.
///
/// `@unchecked Sendable` because AVCaptureSession and MTLDevice are not
/// formally Sendable but are thread-safe for the single-owner usage
/// pattern this class enforces.
final class CameraController: NSObject, @unchecked Sendable {

    // MARK: - Public properties

    /// Called on the internal video queue with each captured frame.
    /// The handler must dispatch to the main actor (or its own queue)
    /// before touching SwiftUI.
    var onFrame: (@Sendable (CameraFrame) -> Void)?

    /// Called on the main queue after `start()` has actually entered
    /// the running state, so the VM can flip its UI flag.
    var onRunningStateChange: (@Sendable (Bool) -> Void)?

    // MARK: - Private

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.dcrdemo.camera.session")
    private let videoQueue = DispatchQueue(label: "com.dcrdemo.camera.video")

    private let textureCache: CVMetalTextureCache?
    private let device: MTLDevice

    // MARK: - Init

    init(device: MTLDevice) {
        self.device = device
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache
        super.init()
    }

    // MARK: - Authorization

    /// Current permission. Snapshot-style; re-query after a prompt.
    static func currentAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Prompt for camera access if not yet determined. Returns whether
    /// access is authorized.
    static func requestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    // MARK: - Lifecycle

    /// Configure and start the back camera. Idempotent.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.session.isRunning else { return }
            self.configureSessionIfNeeded()
            self.session.startRunning()
            if self.session.isRunning {
                let hook = self.onRunningStateChange
                DispatchQueue.main.async {
                    hook?(true)
                }
            }
        }
    }

    /// Stop the session. Idempotent.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            let hook = self.onRunningStateChange
            DispatchQueue.main.async {
                hook?(false)
            }
        }
    }

    // MARK: - Private

    private var didConfigureSession = false

    private func configureSessionIfNeeded() {
        guard !didConfigureSession else { return }
        didConfigureSession = true

        session.beginConfiguration()

        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        guard
            let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            connection.isVideoMirrored = false
        }

        session.commitConfiguration()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard
            let cache = textureCache,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex)
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(CameraFrame(texture: texture, presentationTime: pts))
    }
}
