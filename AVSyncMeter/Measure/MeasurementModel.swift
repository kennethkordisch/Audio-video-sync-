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
    private let captionReader = CaptionReader()
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
        engine.onLumaFrame = { @Sendable [pipeline] frame in pipeline.ingest(frame) }
        engine.onAudio = { @Sendable [pipeline] chunk in pipeline.ingest(chunk) }
        pipeline.onUpdate = { @Sendable [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.receive(snapshot)
            }
        }
        pipeline.onRequestFrame = { @Sendable [engine] in engine.wantsFrameSnapshot = true }
        engine.onFrameSnapshot = { @Sendable [weak self] pixelBuffer, time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let orientation = CaptionReader.orientation(for: UIDevice.current.orientation)
                self.captionReader.read(pixelBuffer, orientation: orientation) { [pipeline] reading in
                    pipeline.attachLabel(eventNumber: reading.eventNumber, timecode: reading.timecode, frameTime: time)
                }
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
        guard phase == .measuring else { return }
        switch settings.mode {
        case .singleEvent:
            return   // keep listening until the user stops
        case .calibration:
            if newSnapshot.summary.count >= settings.targetEventCount { stop() }
        case .repeating:
            if settings.driftMode {
                if elapsedRunSeconds >= Double(settings.driftDurationMinutes) * 60 { stop() }
            } else if newSnapshot.summary.count >= settings.targetEventCount {
                stop()
            }
        }
    }

    // MARK: - Calibration

    /// In calibration mode the reference chain is assumed to be in sync, so whatever offset
    /// remains after removing sound travel is the phone's own camera-vs-microphone bias (seconds).
    var calibrationBias: Double? {
        guard settings.mode == .calibration else { return nil }
        return offsetAtSource
    }

    /// Folds the measured bias into the stored camera offset so future runs read zero on this chain.
    func saveCalibration() {
        guard let bias = calibrationBias else { return }
        let newOffsetMs = settings.cameraTimestampOffsetMs + bias * 1000
        UserDefaults.standard.set(newOffsetMs, forKey: AppSettings.Key.cameraTimestampOffsetMs)
        settings = AppSettings.Snapshot.load()
        calibrationSavedMs = newOffsetMs
    }

    var calibrationSavedMs: Double?

    // MARK: - Saving

    /// Builds a history record from the current results.
    func makeRecord(label: String) -> RunRecord {
        let pairs = snapshot.pairs
        let t0 = pairs.first?.flashTime ?? 0
        let points = pairs.enumerated().map { index, pair in
            RunPoint(id: index, time: pair.flashTime - t0, offsetMs: pair.offset * 1000, band: pair.band, eventNumber: pair.eventNumber)
        }
        let bands = snapshot.bandSummaries
        return RunRecord(
            label: label,
            mode: settings.mode.title + (settings.driftMode && settings.mode == .repeating ? " (drift)" : ""),
            frameRateLabel: frameRate.label,
            fps: frameRate.fps,
            eventCount: snapshot.summary.count,
            offsetAtPhoneMs: (offsetAtListener ?? 0) * 1000,
            offsetAtScreenMs: offsetAtSource.map { $0 * 1000 },
            madMs: (snapshot.summary.mad ?? 0) * 1000,
            distanceMeters: distance?.meters,
            distanceSource: distance?.source.rawValue,
            driftMsPerMinute: snapshot.drift?.slopeMsPerMinute,
            slipCount: snapshot.slips.count,
            leftOffsetMs: bands.count == 2 ? bands[0].median.map { $0 * 1000 } : nil,
            rightOffsetMs: bands.count == 2 ? bands[1].median.map { $0 * 1000 } : nil,
            cameraOffsetMs: settings.cameraTimestampOffsetMs,
            points: points,
            csv: resultsCSV())
    }

    // MARK: - Frames and export

    var frameRate: PatternFrameRate { settings.frameRate }

    /// Seconds between the first and last paired event.
    var elapsedRunSeconds: Double {
        guard let first = snapshot.pairs.first, let last = snapshot.pairs.last else { return 0 }
        return last.flashTime - first.flashTime
    }

    func frames(fromSeconds seconds: Double) -> Double {
        seconds * frameRate.fps
    }

    /// CSV with a metadata header and one row per paired event.
    func resultsCSV() -> String {
        var lines: [String] = []
        let formatter = ISO8601DateFormatter()
        lines.append("# AVSyncMeter results, \(formatter.string(from: Date()))")
        lines.append("# pattern_fps,\(frameRate.label)")
        if let d = distance {
            lines.append(String(format: "# distance_m,%.3f,%@", d.meters, d.source.rawValue))
            lines.append(String(format: "# sound_travel_ms,%.2f", (propagationDelay ?? 0) * 1000))
        } else {
            lines.append("# distance_m,unknown")
        }
        lines.append(String(format: "# speed_of_sound_mps,%.1f", Acoustics.speedOfSound(celsius: settings.roomTemperatureC)))
        if let m = offsetAtListener {
            lines.append(String(format: "# median_offset_at_phone_ms,%.2f", m * 1000))
        }
        if let s = offsetAtSource {
            lines.append(String(format: "# median_offset_at_screen_ms,%.2f", s * 1000))
        }
        if let drift = snapshot.drift {
            lines.append(String(format: "# drift_ms_per_min,%.3f", drift.slopeMsPerMinute))
            lines.append(String(format: "# drift_ppm,%.1f", drift.partsPerMillion))
        }
        lines.append("# sign: positive offset = audio later than video")
        lines.append("event,run_time_s,flash_time_s,beep_time_s,offset_ms,offset_frames,channel,caption_event,caption_timecode")
        let t0 = snapshot.pairs.first?.flashTime ?? 0
        for (i, pair) in snapshot.pairs.enumerated() {
            let channel = settings.channelIDTones ? (pair.band == 0 ? "L" : "R") : "both"
            lines.append(String(format: "%d,%.4f,%.6f,%.6f,%.3f,%.3f,%@,%@,%@",
                                i + 1, pair.flashTime - t0, pair.flashTime, pair.beepTime,
                                pair.offset * 1000, frames(fromSeconds: pair.offset),
                                channel, pair.eventNumber.map(String.init) ?? "", pair.timecode ?? ""))
        }
        return lines.joined(separator: "\n") + "\n"
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
