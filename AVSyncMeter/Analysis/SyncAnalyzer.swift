import Foundation

struct SyncPair {
    let flashTime: Double
    let beepTime: Double
    /// Positive: audio arrives after video (audio lags). Seconds.
    var offset: Double { beepTime - flashTime }
}

struct SyncSummary {
    var count: Int = 0
    var median: Double?
    var mad: Double?
    var mean: Double?
    var standardDeviation: Double?
    var min: Double?
    var max: Double?

    static let empty = SyncSummary()

    init() {}

    init(offsets: [Double]) {
        count = offsets.count
        median = Statistics.median(offsets)
        mad = Statistics.mad(offsets)
        mean = Statistics.mean(offsets)
        standardDeviation = Statistics.standardDeviation(offsets)
        min = offsets.min()
        max = offsets.max()
    }
}

/// Pairs flash onsets with beep onsets and accumulates the offsets.
struct SyncAnalyzer {
    /// |beep - flash| must be below this to pair. Events are 2 s apart, so 0.6 s is safe.
    var pairingWindow: Double = 0.6

    private(set) var pairs: [SyncPair] = []
    private(set) var flashCount = 0
    private(set) var beepCount = 0
    private var unpairedFlashes: [Double] = []
    private var unpairedBeeps: [Double] = []

    mutating func reset() {
        self = SyncAnalyzer(pairingWindow: pairingWindow)
    }

    mutating func addFlash(_ t: Double) {
        flashCount += 1
        unpairedFlashes.append(t)
        pairEvents(now: t)
    }

    mutating func addBeep(_ t: Double) {
        beepCount += 1
        unpairedBeeps.append(t)
        pairEvents(now: t)
    }

    var offsets: [Double] { pairs.map(\.offset) }
    var summary: SyncSummary { SyncSummary(offsets: offsets) }

    private mutating func pairEvents(now: Double) {
        // Greedy nearest-neighbour pairing within the window.
        while true {
            var best: (fi: Int, bi: Int, d: Double)?
            for (fi, f) in unpairedFlashes.enumerated() {
                for (bi, b) in unpairedBeeps.enumerated() {
                    let d = abs(b - f)
                    if d < pairingWindow && (best == nil || d < best!.d) {
                        best = (fi, bi, d)
                    }
                }
            }
            guard let match = best else { break }
            pairs.append(SyncPair(flashTime: unpairedFlashes[match.fi], beepTime: unpairedBeeps[match.bi]))
            unpairedFlashes.remove(at: match.fi)
            unpairedBeeps.remove(at: match.bi)
        }
        // Forget events that can no longer be paired.
        let horizon = 2 * pairingWindow
        unpairedFlashes.removeAll { now - $0 > horizon }
        unpairedBeeps.removeAll { now - $0 > horizon }
    }
}
