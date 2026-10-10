import Foundation

/// Reference tolerances for lip sync. Offsets are in milliseconds, positive = audio late.
enum SyncStandards {
    struct Verdict {
        enum Severity: Int { case good, noticeable, bad }
        let severity: Severity
        let title: String
        let detail: String
    }

    /// EBU R37: sound should not lead by more than 40 ms or lag by more than 60 ms.
    static let ebuLeadLimitMs = 40.0
    static let ebuLagLimitMs = 60.0
    /// ITU-R BT.1359-1 detectability thresholds: 45 ms lead, 125 ms lag.
    static let ituDetectLeadMs = 45.0
    static let ituDetectLagMs = 125.0
    /// ITU-R BT.1359-1 acceptability thresholds: 90 ms lead, 185 ms lag.
    static let ituAcceptLeadMs = 90.0
    static let ituAcceptLagMs = 185.0

    static func verdict(offsetMs: Double) -> Verdict {
        if offsetMs >= -ebuLeadLimitMs && offsetMs <= ebuLagLimitMs {
            return Verdict(severity: .good,
                           title: "Within EBU R37 tolerance",
                           detail: "Inside the -40 ms (lead) / +60 ms (lag) window most viewers cannot notice.")
        }
        if offsetMs >= -ituDetectLeadMs && offsetMs <= ituDetectLagMs {
            return Verdict(severity: .noticeable,
                           title: "Borderline",
                           detail: "Outside EBU R37 but still under the ITU-R BT.1359 detectability threshold (-45 / +125 ms).")
        }
        if offsetMs >= -ituAcceptLeadMs && offsetMs <= ituAcceptLagMs {
            return Verdict(severity: .noticeable,
                           title: "Noticeable",
                           detail: "Most viewers will see this. Still inside the ITU-R BT.1359 acceptability limits (-90 / +185 ms).")
        }
        return Verdict(severity: .bad,
                       title: "Out of sync",
                       detail: "Beyond the ITU-R BT.1359 acceptability limits. Adjust the audio delay on the AVR/soundbar or TV.")
    }

    static func describe(offsetMs: Double) -> String {
        let magnitude = abs(offsetMs)
        if magnitude < 1.5 { return "Audio and video are in sync" }
        let value = magnitude < 10 ? String(format: "%.1f", magnitude) : String(format: "%.0f", magnitude)
        return offsetMs > 0 ? "Audio lags video by \(value) ms" : "Audio leads video by \(value) ms"
    }
}
