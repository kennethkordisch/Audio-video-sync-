import AVFoundation
import Foundation
import simd

/// One camera frame reduced to luminance statistics.
struct LumaFrame {
    /// Presentation timestamp on the capture-session clock (seconds). Audio chunks use the same clock.
    let time: Double
    let exposureDuration: Double
    let mean: Double
    let cells: [Float]
    let cols: Int
    let rows: Int
    let width: Int
    let height: Int
    /// Focal length in pixels of the delivered frame (from the camera intrinsic matrix), if available.
    let focalLengthPixels: Double?
}

/// Runs an AVCaptureSession with a high-frame-rate back camera and the microphone, delivering
/// luminance frames and audio chunks that share one clock.
final class CaptureEngine: NSObject {
    enum CaptureError: LocalizedError {
        case noCamera, noMicrophone, cannotAddInput, cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No back camera available."
            case .noMicrophone: return "No microphone available."
            case .cannotAddInput: return "Could not attach the camera or microphone."
            case .cannotAddOutput: return "Could not attach capture outputs."
            }
        }
    }

    let session = AVCaptureSession()

    /// Called on a background queue for every camera frame.
    var onLumaFrame: (@Sendable (LumaFrame) -> Void)?
    /// Called on a background queue for every audio buffer.
    var onAudio: (@Sendable (AudioSampleConverter.Chunk) -> Void)?

    /// Set to true to receive the next full frame through `onFrameSnapshot` (one shot).
    var wantsFrameSnapshot = false
    /// Called on the video queue with a retained pixel buffer and its capture time.
    var onFrameSnapshot: (@Sendable (CVPixelBuffer, Double) -> Void)?

    private(set) var nominalFrameRate: Double = 0
    private(set) var formatSummary: String = ""

    private let sessionQueue = DispatchQueue(label: "AVSyncMeter.capture.session")
    private let videoQueue = DispatchQueue(label: "AVSyncMeter.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "AVSyncMeter.capture.audio", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var videoDevice: AVCaptureDevice?
    private var configured = false

    // MARK: Lifecycle

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if !self.configured {
                        try self.configure()
                        self.configured = true
                    }
                    self.resetExposureToAuto()
                    self.session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // MARK: Exposure control

    /// Bias auto exposure (EV) so the white flash does not clip hard.
    func setExposureBias(_ bias: Float) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                let clamped = max(device.minExposureTargetBias, min(device.maxExposureTargetBias, bias))
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
                return
            }
        }
    }

    /// Freeze exposure, white balance and focus so the camera does not react to the flash.
    func lockExposureFocusAndWhiteBalance() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                device.unlockForConfiguration()
            } catch {
                return
            }
        }
    }

    private func resetExposureToAuto() {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.setExposureTargetBias(0, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            return
        }
    }

    // MARK: Configuration

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .inputPriority

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else { throw CaptureError.cannotAddInput }
        session.addInput(cameraInput)
        videoDevice = camera

        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CaptureError.noMicrophone }
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(microphoneInput) else { throw CaptureError.cannotAddInput }
        session.addInput(microphoneInput)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)

        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(audioOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(audioOutput)

        try selectHighFrameRateFormat(for: camera)

        if let connection = videoOutput.connection(with: .video),
           connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }

    /// Picks the 8-bit 4:2:0 format with the highest frame rate (capped at 240 fps) at 1080p or
    /// below, preferring the smaller frame on ties. Higher frame rates mean finer flash timing.
    private func selectHighFrameRateFormat(for device: AVCaptureDevice) throws {
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
            min(240, f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        func area(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }

        let candidates = device.formats.filter { f in
            let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            guard subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width <= 1920 && d.width >= 1280
        }

        guard let best = candidates.max(by: { a, b in
            let fa = maxFPS(a), fb = maxFPS(b)
            if fa != fb { return fa < fb }
            return area(a) > area(b)
        }) else { return }

        // Take the frame duration from the range itself: a duration outside the supported range
        // raises an Objective-C exception that Swift cannot catch.
        guard let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }),
              range.maxFrameRate > 0 else { return }
        let fps = min(240, range.maxFrameRate)
        let duration = fps < range.maxFrameRate
            ? CMTime(value: 1, timescale: CMTimeScale(fps.rounded(.down)))
            : range.minFrameDuration

        try device.lockForConfiguration()
        device.activeFormat = best
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()

        nominalFrameRate = fps
        let d = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
        formatSummary = "\(d.width)x\(d.height) @ \(Int(fps)) fps"
    }
}

// MARK: - Sample buffer delegates

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let onLumaFrame, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        if wantsFrameSnapshot, let onFrameSnapshot {
            wantsFrameSnapshot = false
            onFrameSnapshot(pixelBuffer, pts)
        }

        var focal: Double?
        if let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil),
           let data = attachment as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
            focal = Double((m.columns.0.x + m.columns.1.y) / 2)
        }

        let exposure = videoDevice.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0
        guard let stats = LuminanceSampler.sample(pixelBuffer) else { return }
        onLumaFrame(LumaFrame(time: pts,
                              exposureDuration: exposure.isFinite ? exposure : 0,
                              mean: stats.mean,
                              cells: stats.cells,
                              cols: LuminanceSampler.cols,
                              rows: LuminanceSampler.rows,
                              width: CVPixelBufferGetWidth(pixelBuffer),
                              height: CVPixelBufferGetHeight(pixelBuffer),
                              focalLengthPixels: focal))
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let onAudio, let chunk = AudioSampleConverter.monoFloat(from: sampleBuffer) else { return }
        onAudio(chunk)
    }
}
