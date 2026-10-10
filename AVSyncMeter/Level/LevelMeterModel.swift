import AVFoundation
import Foundation
import Observation

/// UI-facing state for the Level tab.
@MainActor
@Observable
final class LevelMeterModel {
    var snapshot = LevelSnapshot()
    var isRunning = false
    var errorMessage: String?

    private let engine = LevelMeterEngine()

    init() {
        engine.onUpdate = { @Sendable [weak self] snapshot in
            Task { @MainActor [weak self] in self?.snapshot = snapshot }
        }
    }

    func apply(offset: Double, weighting: Weighting, timeWeighting: TimeWeighting, layout: SpeakerLayout, target: Double) {
        engine.calibrationOffset = offset
        engine.weighting = weighting
        engine.timeWeighting = timeWeighting
        engine.layout = layout
        engine.gateThreshold = target - 20
    }

    func start() {
        guard !isRunning else { return }
        Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            guard allowed else {
                errorMessage = "Microphone access is required."
                return
            }
            do {
                try engine.start()
                isRunning = true
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        engine.stop()
        isRunning = false
    }

    func resetLeq() { engine.resetLeq() }
    func startSequence() { engine.startSequence() }
    func stopSequence() { engine.stopSequence() }
    func capture(channel: String, seconds: Double) { engine.capture(channel: channel, seconds: seconds) }
    func cancelCapture() { engine.cancelCapture() }
    func clearReadings() { engine.clearReadings() }
    func removeReading(named name: String) { engine.removeReading(named: name) }

    /// Target for a channel: LFE gets the extra in-band offset.
    func target(for name: String, base: Double, lfeOffset: Double) -> Double {
        name == "LFE" ? base + lfeOffset : base
    }

    func readingsCSV(layout: SpeakerLayout, target: Double, lfeOffset: Double, offset: Double, weighting: Weighting) -> String {
        var lines = ["# AVSyncMeter speaker levels, \(ISO8601DateFormatter().string(from: Date()))",
                     "# layout,\(layout.rawValue)", String(format: "# target_db,%.1f", target),
                     String(format: "# lfe_offset_db,%.1f", lfeOffset), String(format: "# calibration_offset_db,%.1f", offset),
                     "# leq_weighting,C", "channel,leq_db_spl,target_db,trim_db,seconds"]
        for r in snapshot.readings {
            let t = self.target(for: r.name, base: target, lfeOffset: lfeOffset)
            lines.append(String(format: "%@,%.1f,%.1f,%+.1f,%.1f", r.name, r.leq, t, t - r.leq, r.duration))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
