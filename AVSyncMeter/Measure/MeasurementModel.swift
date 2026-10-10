import AVFoundation
import Foundation
import Observation
import UIKit

enum DistanceSource: String {
    case manual = "manual"
    case lidar = "LiDAR"
    case camera = "camera estimate"
}

/// Drives one measurement run: permissions -> LiDAR ranging -> camera start -> exposure
/// settle/lock -> measuring until the target number of events is reached.
@MainActor
@Observable
final class MeasurementModel {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case ranging
        case startingCamera
        case settling
        case measuring
        case finished
        case failed(String)
    }

    struct Distance {
        let meters: Double
        let source: DistanceSource
    }

    var phase: Phase = .idle
    var snapshot = AnalysisPipeline.Snapshot.empty
    var settings = AppSettings.Snapshot.load()
    var lidarDistance: Double?
    var lidarSampleCount = 0
    var formatSummary = ""
    let lidarSupported = LiDARRanger.isSupported

    private let engine = CaptureEngine()
    private let pipeline = AnalysisPipeline()
    private var ranger: LiDARRanger?
    private var runTask: Task<Void, Never>?

    var captureSession: AVCaptureSession { engine.session }

    var isRunning: Bool {
        switch phase {
        case .idle, .finished, .failed: return false
        default: return true
        }
    }

    init() {
        engine.onLumaFrame = { [pipeline] frame in pipeline.ingest(frame) }
        engine.onAudio = { [pipeline] chunk in pipeline.ingest(chunk) }
        pipeline.onUpdate = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.receive(snapshot)
            }
        }
    }

    // MARK: - Derived results

    /// Distance used for the sound-travel correction, by priority: manual, LiDAR, camera estimate.
    var distance: Distance? {
        if settings.useManualDistance {
            return Distance(meters: settings.manualDistanceMeters, source: .manual)
        }
        if let d = lidarDistance {
            return Distance(meters: d, source: .lidar)
        }
        if let d = snapshot.cameraDistance, snapshot.cameraDistanceSamples >= 2 {
            return Distance(meters: d, source: .camera)
        }
        return nil
    }

    var propagationDelay: TimeInterval? {
        distance.map { Acoustics.propagationDelay(distanceMeters: $0.meters, celsius: settings.roomTemperatureC) }
    }

    /// Median (beep - flash) as observed at the phone, seconds. Positive = audio late.
    var offsetAtListener: Double? { snapshot.summary.median }

    /// Offset with the sound's travel time removed: what the display/speaker chain itself does.
    var offsetAtSource: Double? {
        guard let listener = offsetAtListener, let travel = propagationDelay else { return nil }
        return listener - travel
    }

    // MARK: - Control

    func refreshSettings() {
        guard !isRunning else { return }
        settings = AppSettings.Snapshot.load()
    }

    func start() {
        guard !isRunning else { return }
        runTask = Task { await run() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        ranger?.stop()
        ranger = nil
        engine.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if isRunning {
            phase = snapshot.summary.count > 0 ? .finished : .idle
        }
    }

    private func receive(_ newSnapshot: AnalysisPipeline.Snapshot) {
        snapshot = newSnapshot
        if phase == .measuring, newSnapshot.summary.count >= settings.targetEventCount {
            stop()
        }
    }

    private func run() async {
        settings = AppSettings.Snapshot.load()
        snapshot = .empty
        lidarDistance = nil
        lidarSampleCount = 0
        formatSummary = ""

        phase = .requestingPermission
        let cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        if Task.isCancelled { return }
        guard cameraAllowed, microphoneAllowed else {
            phase = .failed("Camera and microphone access are required. Allow both in Settings > Privacy & Security.")
            return
        }

        if !settings.useManualDistance && lidarSupported {
            phase = .ranging
            let ranger = LiDARRanger()
            self.ranger = ranger
            ranger.start()
            for _ in 0..<40 {   // up to 4 s
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                lidarDistance = ranger.estimate
                lidarSampleCount = ranger.sampleCount
                if ranger.sampleCount >= 25 { break }
            }
            ranger.stop()
            self.ranger = nil
            // Give ARKit a moment to release the camera before AVFoundation claims it.
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
        }

        phase = .startingCamera
        pipeline.reset(settings: settings)
        do {
            try await engine.start()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        if Task.isCancelled { engine.stop(); return }
        formatSummary = engine.formatSummary
        UIApplication.shared.isIdleTimerDisabled = true

        // Let auto exposure settle on the scene, back it off so white does not clip hard, then freeze
        // everything so the camera cannot react to the flashes.
        phase = .settling
        try? await Task.sleep(for: .seconds(1.2))
        if Task.isCancelled { return }
        engine.setExposureBias(-1.0)
        try? await Task.sleep(for: .seconds(1.3))
        if Task.isCancelled { return }
        engine.lockExposureFocusAndWhiteBalance()
        try? await Task.sleep(for: .milliseconds(400))
        if Task.isCancelled { return }

        pipeline.reset(settings: settings)
        phase = .measuring
    }
}
