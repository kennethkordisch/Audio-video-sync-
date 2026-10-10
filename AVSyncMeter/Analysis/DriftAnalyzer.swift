import Foundation

/// Linear trend of the A/V offset over a run: does audio drift relative to video?
struct DriftEstimate {
    /// Change of offset per minute of playback (ms/min). Positive: audio falls progressively later.
    let slopeMsPerMinute: Double
    /// Fitted offset at the first event (ms).
    let interceptMs: Double
    let spanSeconds: Double
    let count: Int
    /// Spread of the events around the fitted line (ms).
    let residualMadMs: Double

    var totalDriftMs: Double { slopeMsPerMinute * spanSeconds / 60 }
    /// Relative speed difference between the audio and video clocks, in parts per million.
    var partsPerMillion: Double { slopeMsPerMinute / 60_000 * 1_000_000 }

    func framesPerHour(fps: Double) -> Double { slopeMsPerMinute * 60 / 1000 * fps }
}

/// A sudden step in the offset, e.g. a dropped or repeated frame.
struct FrameSlip: Identifiable {
    /// Index of the first event after the step.
    let id: Int
    /// Seconds after the first event.
    let time: Double
    /// Step size (ms). Positive: audio became later.
    let deltaMs: Double
}

enum DriftAnalyzer {
    static let minimumCount = 6
    static let minimumSpanSeconds = 20.0
    /// Theil-Sen is O(n^2); beyond this many events the series is subsampled evenly.
    static let maximumFitPoints = 400

    /// Robust (Theil-Sen) straight-line fit of offset versus time.
    static func estimate(pairs: [SyncPair]) -> DriftEstimate? {
        guard pairs.count >= minimumCount, let first = pairs.first, let last = pairs.last else { return nil }
        let t0 = first.flashTime
        let span = last.flashTime - t0
        guard span >= minimumSpanSeconds else { return nil }

        var points = pairs
        if points.count > maximumFitPoints {
            let step = Double(points.count - 1) / Double(maximumFitPoints - 1)
            points = (0..<maximumFitPoints).map { pairs[Int((Double($0) * step).rounded())] }
        }
        let xs = points.map { ($0.flashTime - t0) / 60 }   // minutes
        let ys = points.map { $0.offset * 1000 }           // ms

        var slopes: [Double] = []
        slopes.reserveCapacity(xs.count * (xs.count - 1) / 2)
        for i in 0..<xs.count {
            for j in (i + 1)..<xs.count where xs[j] > xs[i] {
                slopes.append((ys[j] - ys[i]) / (xs[j] - xs[i]))
            }
        }
        guard let slope = Statistics.median(slopes),
              let intercept = Statistics.median(zip(xs, ys).map { $1 - slope * $0 }) else { return nil }
        let residuals = zip(xs, ys).map { $1 - (intercept + slope * $0) }
        return DriftEstimate(slopeMsPerMinute: slope,
                             interceptMs: intercept,
                             spanSeconds: span,
                             count: pairs.count,
                             residualMadMs: Statistics.mad(residuals) ?? 0)
    }

    /// Matches the measured clock ratio against the usual suspects.
    static func interpretation(of estimate: DriftEstimate) -> String {
        let ppm = estimate.partsPerMillion
        let magnitude = abs(ppm)
        let direction = ppm > 0 ? "audio runs slow (falls further behind)" : "audio runs fast (gets further ahead)"

        func near(_ target: Double, tolerance: Double = 0.15) -> Bool {
            abs(magnitude - target) <= target * tolerance
        }

        if magnitude < 25 {
            return "No meaningful drift (under 1.5 ms per minute). Clocks are locked."
        }
        if near(999) || near(1001) {
            return "0.1% mismatch (1000/1001), \(direction). Classic pull-down error: 23.976 vs 24 fps, 29.97 vs 30 fps, or 48 kHz audio against 48.048 kHz."
        }
        if near(40_000) || near(41_667) {
            return "About 4% mismatch (24 vs 25 fps), \(direction). PAL/film speed change without matching audio."
        }
        if near(81_633) || near(88_435) {
            return "About 8.5% mismatch (44.1 vs 48 kHz), \(direction). Audio sample-rate mismatch."
        }
        return String(format: "%.0f ppm (%.3f%%) clock mismatch, %@. Not one of the common ratios; check sample-rate conversion and playback hardware clocking.",
                      magnitude, magnitude / 10_000, direction)
    }

    /// Finds steps of at least half a frame in the (detrended) offset series. A step must hold for
    /// the next two events so a single noisy pair does not count.
    static func slips(pairs: [SyncPair], frameDurationMs: Double, slopeMsPerMinute: Double?) -> [FrameSlip] {
        guard pairs.count >= 5, frameDurationMs > 0 else { return [] }
        let t0 = pairs[0].flashTime
        let slope = (slopeMsPerMinute ?? 0) / 60   // ms per second
        let y = pairs.map { ($0.offset * 1000) - slope * ($0.flashTime - t0) }
        let threshold = 0.5 * frameDurationMs

        var slips: [FrameSlip] = []
        var level = Statistics.median(Array(y[0..<3])) ?? y[0]
        var i = 3
        while i < y.count {
            let d = y[i] - level
            if abs(d) > threshold {
                let confirmIndices = (i + 1)..<min(i + 3, y.count)
                let confirmed = confirmIndices.count == 2 && confirmIndices.allSatisfy {
                    let e = y[$0] - level
                    return abs(e) > threshold && (e > 0) == (d > 0)
                }
                if confirmed {
                    let newLevel = Statistics.median(Array(y[i...(i + 2)])) ?? y[i]
                    slips.append(FrameSlip(id: i, time: pairs[i].flashTime - t0, deltaMs: newLevel - level))
                    level = newLevel
                    i += 3
                    continue
                }
                // Isolated outlier: ignore it.
            } else {
                level = 0.8 * level + 0.2 * y[i]
            }
            i += 1
        }
        return slips
    }
}
