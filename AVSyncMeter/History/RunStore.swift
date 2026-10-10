import Foundation
import Observation
import SwiftUI

/// One point of an offset-vs-time series, for charts and reports.
struct RunPoint: Codable, Identifiable {
    var id: Int
    /// Seconds after the first event.
    var time: Double
    var offsetMs: Double
    var band: Int
    var eventNumber: Int?
}

/// A saved measurement run.
struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// Free text: the chain or the seat, e.g. "DNxIO HDMI, mix position".
    var label: String
    var mode: String
    var frameRateLabel: String
    var fps: Double
    var eventCount: Int
    var offsetAtPhoneMs: Double
    var offsetAtScreenMs: Double?
    var madMs: Double
    var distanceMeters: Double?
    var distanceSource: String?
    var driftMsPerMinute: Double?
    var slipCount: Int
    var leftOffsetMs: Double?
    var rightOffsetMs: Double?
    var cameraOffsetMs: Double
    var points: [RunPoint]
    var csv: String

    /// The number to quote: at the screen when a distance was known, else at the phone.
    var headlineOffsetMs: Double { offsetAtScreenMs ?? offsetAtPhoneMs }
    var headlineOffsetFrames: Double { headlineOffsetMs / 1000 * fps }
}

/// Persists runs as JSON in Application Support.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [RunRecord] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("AVSyncMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("runs.json")
    }

    init() {
        load()
    }

    func add(_ record: RunRecord) {
        runs.insert(record, at: 0)
        save()
    }

    func update(_ record: RunRecord) {
        guard let index = runs.firstIndex(where: { $0.id == record.id }) else { return }
        runs[index] = record
        save()
    }

    func delete(_ record: RunRecord) {
        runs.removeAll { $0.id == record.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        runs.remove(atOffsets: offsets)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([RunRecord].self, from: data) else { return }
        runs = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(runs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
