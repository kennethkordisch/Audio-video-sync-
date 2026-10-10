import Foundation

/// What a measurement run is for.
enum MeasurementMode: String, CaseIterable, Identifiable {
    /// Repeating flash/beep pattern; stop after N events or a drift run.
    case repeating
    /// Catch individual pops (2-pops, sync plops); never stops on its own.
    case singleEvent
    /// Measure a known-good reference chain to learn the phone's own camera/mic bias.
    case calibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .repeating: return "Pattern"
        case .singleEvent: return "Two-pop"
        case .calibration: return "Calibrate"
        }
    }
}

/// User-adjustable parameters, stored in UserDefaults (bound with @AppStorage in SettingsView).
enum AppSettings {
    enum Key {
        static let screenDiagonalInches = "screenDiagonalInches"
        static let roomTemperatureC = "roomTemperatureC"
        static let useManualDistance = "useManualDistance"
        static let manualDistanceMeters = "manualDistanceMeters"
        static let useExposureMidpoint = "useExposureMidpoint"
        static let cameraTimestampOffsetMs = "cameraTimestampOffsetMs"
        static let minFlashContrast = "minFlashContrast"
        static let targetEventCount = "targetEventCount"
        static let patternFrameRate = "patternFrameRate"
        static let driftMode = "driftMode"
        static let driftDurationMinutes = "driftDurationMinutes"
        static let measurementMode = "measurementMode"
        static let channelIDTones = "channelIDTones"
        static let readCaption = "readCaption"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.screenDiagonalInches: 65.0,
            Key.roomTemperatureC: 20.0,
            Key.useManualDistance: false,
            Key.manualDistanceMeters: 3.0,
            Key.useExposureMidpoint: true,
            Key.cameraTimestampOffsetMs: 0.0,
            Key.minFlashContrast: 12.0,
            Key.targetEventCount: 20,
            Key.patternFrameRate: TestPattern.defaultFrameRate.fps,
            Key.driftMode: false,
            Key.driftDurationMinutes: 5,
            Key.measurementMode: MeasurementMode.repeating.rawValue,
            Key.channelIDTones: false,
            Key.readCaption: true,
        ])
    }

    /// Immutable copy of the settings taken at the start of a measurement run.
    struct Snapshot {
        var screenDiagonalInches: Double
        var roomTemperatureC: Double
        var useManualDistance: Bool
        var manualDistanceMeters: Double
        var useExposureMidpoint: Bool
        var cameraTimestampOffsetMs: Double
        var minFlashContrast: Double
        var targetEventCount: Int
        var patternFrameRate: Double
        var driftMode: Bool
        var driftDurationMinutes: Int
        var mode: MeasurementMode
        var channelIDTones: Bool
        var readCaption: Bool

        var screenDiagonalMeters: Double { screenDiagonalInches * 0.0254 }
        var frameRate: PatternFrameRate { TestPattern.frameRate(matching: patternFrameRate) }

        static func load() -> Snapshot {
            let d = UserDefaults.standard
            return Snapshot(
                screenDiagonalInches: d.double(forKey: Key.screenDiagonalInches),
                roomTemperatureC: d.double(forKey: Key.roomTemperatureC),
                useManualDistance: d.bool(forKey: Key.useManualDistance),
                manualDistanceMeters: d.double(forKey: Key.manualDistanceMeters),
                useExposureMidpoint: d.bool(forKey: Key.useExposureMidpoint),
                cameraTimestampOffsetMs: d.double(forKey: Key.cameraTimestampOffsetMs),
                minFlashContrast: d.double(forKey: Key.minFlashContrast),
                targetEventCount: max(3, d.integer(forKey: Key.targetEventCount)),
                patternFrameRate: d.double(forKey: Key.patternFrameRate),
                driftMode: d.bool(forKey: Key.driftMode),
                driftDurationMinutes: max(1, d.integer(forKey: Key.driftDurationMinutes)),
                mode: MeasurementMode(rawValue: d.string(forKey: Key.measurementMode) ?? "") ?? .repeating,
                channelIDTones: d.bool(forKey: Key.channelIDTones),
                readCaption: d.bool(forKey: Key.readCaption)
            )
        }
    }
}
