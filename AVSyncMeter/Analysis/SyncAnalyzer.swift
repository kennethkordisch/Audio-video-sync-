import Foundation

struct SyncPair {
    let flashTime: Double
    let beepTime: Double
    /// Tone band of the beep: 0 = base tone (left in channel-ID patterns), 1 = right.
    var band: Int = 0
    /// Event number read from the burned-in caption, if OCR managed it.
    var eventNumber: Int?
    /// Timecode read from the burned-in caption, if any.
    var timecode: String?
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
    private var unpairedBeeps: [(time: Double, band: Int)] = []

    mutating func reset() {
        self = SyncAnalyzer(pairingWindow: pairingWindow)
    }

    mutating func addFlash(_ t: Double) {
        flashCount += 1
        unpairedFlashes.append(t)
        pairEvents(now: t)
    }

    mutating func addBeep(_ t: Double, band: Int = 0) {
        beepCount += 1
        unpairedBeeps.append((t, band))
        pairEvents(now: t)
    }

    /// Attaches an OCR label to the most recent pair whose flash is within `window` of `time`.
    mutating func label(eventNumber: Int?, timecode: String?, nearFlashTime time: Double, window: Double = 1.5) {
        guard let index = pairs.indices.last(where: { abs(pairs[$0].flashTime - time) < window }) else { return }
        if let eventNumber { pairs[index].eventNumber = eventNumber }
        if let timecode { pairs[index].timecode = timecode }
    }

    var offsets: [Double] { pairs.map(\.offset) }
    var summary: SyncSummary { SyncSummary(offsets: offsets) }
    func summary(band: Int) -> SyncSummary { SyncSummary(offsets: pairs.filter { $0.band == band }.map(\.offset)) }

    private mutating func pairEvents(now: Double) {
        // Greedy nearest-neighbour pairing within the window.
        while true {
            var best: (fi: Int, bi: Int, d: Double)?
            for (fi, f) in unpairedFlashes.enumerated() {
                for (bi, beep) in unpairedBeeps.enumerated() {
                    let d = abs(beep.time - f)
                    if d < pairingWindow && (best == nil || d < best!.d) {
                        best = (fi, bi, d)
                    }
                }
            }
            guard let match = best else { break }
            pairs.append(SyncPair(flashTime: unpairedFlashes[match.fi],
                                  beepTime: unpairedBeeps[match.bi].time,
                                  band: unpairedBeeps[match.bi].band))
            unpairedFlashes.remove(at: match.fi)
            unpairedBeeps.remove(at: match.bi)
        }
        // Forget events that can no longer be paired.
        let horizon = 2 * pairingWindow
        unpairedFlashes.removeAll { now - $0 > horizon }
        unpairedBeeps.removeAll { now - $0.time > horizon }
    }
}
