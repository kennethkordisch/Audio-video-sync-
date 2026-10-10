import AVFoundation
import Foundation

enum TimeWeighting: String, CaseIterable, Identifiable {
    case fast = "Fast"
    case slow = "Slow"
    var id: String { rawValue }
    /// Exponential time constant (seconds).
    var timeConstant: Double { self == .fast ? 0.125 : 1.0 }
}

/// Speaker layouts for pink-noise calibration files. Channel order matches the Mac app and
/// tools/make_pink_noise.sh.
enum SpeakerLayout: String, CaseIterable, Identifiable {
    case stereo = "Stereo"
    case threeOne = "3.1"
    case fiveOne = "5.1"
    case sevenOne = "7.1"
    var id: String { rawValue }

    var channels: [String] {
        switch self {
        case .stereo: return ["L", "R"]
        case .threeOne: return ["L", "R", "C", "LFE"]
        case .fiveOne: return ["L", "R", "C", "LFE", "Ls", "Rs"]
        case .sevenOne: return ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]
        }
    }
}

struct ChannelReading: Identifiable {
    let id: Int
    let name: String
    /// C-weighted Leq over the segment, dB SPL (after calibration offset).
    let leq: Double
    let duration: Double
}

struct LevelSnapshot {
    var level = -120.0          // selected weighting + time weighting, dB SPL
    var levelA = -120.0, levelC = -120.0, levelZ = -120.0   // slow, dB SPL, for the small row
    var peak = -120.0
    var leq = -120.0            // since reset, selected weighting
    var leqSeconds = 0.0
    var dbfs = -120.0           // slow, selected weighting, before the calibration offset
    var sequenceActive = false
    var segmentInProgress = false
    var currentSegmentLevel: Double?
    var readings: [ChannelReading] = []
}

/// Microphone level meter on AVAudioEngine with the measurement audio-session mode (no AGC,
/// no processing). Computes A/C/Z weighted levels, Leq, peak, and gates pink-noise segments.
final class LevelMeterEngine {
    var onUpdate: (@Sendable (LevelSnapshot) -> Void)?

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "AVSyncMeter.level", qos: .userInteractive)
    private var running = false

    // Parameters (set from the main thread; read on the audio thread; benign races).
    var calibrationOffset = 120.0
    var weighting: Weighting = .c
    var timeWeighting: TimeWeighting = .slow
    var gateThreshold = 65.0         // dB SPL: pink segment considered "on" above this
    var layout: SpeakerLayout = .fiveOne

    // State
    private var sampleRate = 48000.0
    private var filters: [Weighting: WeightingFilter] = [:]
    private var meanSquare: [Weighting: Double] = [:]          // slow
    private var meanSquareFast: [Weighting: Double] = [:]
    private var leqSum: [Weighting: Double] = [:]
    private var leqCount = 0
    private var peak = 0.0
    private var lastEmit = 0.0

    // Sequence gating
    private var sequenceActive = false
    private var readings: [ChannelReading] = []
    private var gateAboveSince: Double?
    private var gateBelowSince: Double?
    private var segmentStart: Double?
    private var segmentSum = 0.0
    private var segmentCount = 0
    private var processedSeconds = 0.0

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setPreferredSampleRate(48000)
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        resetState()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.queue.async { self?.process(buffer) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resetLeq() {
        queue.async {
            self.leqSum = [:]
            self.leqCount = 0
            self.peak = 0
        }
    }

    func startSequence() {
        queue.async {
            self.sequenceActive = true
            self.readings = []
            self.gateAboveSince = nil
            self.gateBelowSince = nil
            self.segmentStart = nil
        }
    }

    func stopSequence() {
        queue.async {
            self.sequenceActive = false
            self.segmentStart = nil
        }
    }

    private func resetState() {
        filters = Dictionary(uniqueKeysWithValues: Weighting.allCases.map { ($0, WeightingFilter(weighting: $0, sampleRate: sampleRate)) })
        meanSquare = [:]
        meanSquareFast = [:]
        leqSum = [:]
        leqCount = 0
        peak = 0
        processedSeconds = 0
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let alphaSlow = 1 - exp(-1.0 / (TimeWeighting.slow.timeConstant * sampleRate))
        let alphaFast = 1 - exp(-1.0 / (TimeWeighting.fast.timeConstant * sampleRate))

        var sums: [Weighting: Double] = [:]
        for i in 0..<n {
            let x = Double(channel[i])
            if abs(x) > peak { peak = abs(x) }
            for w in Weighting.allCases {
                var filter = filters[w]!
                let y = filter.process(x)
                filters[w] = filter
                let sq = y * y
                sums[w, default: 0] += sq
                meanSquare[w] = (meanSquare[w] ?? sq) + alphaSlow * (sq - (meanSquare[w] ?? sq))
                meanSquareFast[w] = (meanSquareFast[w] ?? sq) + alphaFast * (sq - (meanSquareFast[w] ?? sq))
            }
        }
        for w in Weighting.allCases { leqSum[w, default: 0] += sums[w] ?? 0 }
        leqCount += n
        processedSeconds += Double(n) / sampleRate

        updateSequence(blockSumC: sums[.c] ?? 0, blockCount: n)

        let now = processedSeconds
        if now - lastEmit >= 0.1 {
            lastEmit = now
            onUpdate?(makeSnapshot())
        }
    }

    private func db(_ meanSquareValue: Double?) -> Double {
        guard let v = meanSquareValue, v > 1e-20 else { return -120 }
        return 10 * log10(v)
    }

    private func makeSnapshot() -> LevelSnapshot {
        var s = LevelSnapshot()
        let selected = timeWeighting == .slow ? meanSquare[weighting] : meanSquareFast[weighting]
        s.dbfs = db(selected)
        s.level = s.dbfs + calibrationOffset
        s.levelA = db(meanSquare[.a]) + calibrationOffset
        s.levelC = db(meanSquare[.c]) + calibrationOffset
        s.levelZ = db(meanSquare[.z]) + calibrationOffset
        s.peak = (peak > 1e-10 ? 20 * log10(peak) : -120) + calibrationOffset
        if leqCount > 0 {
            s.leq = db((leqSum[weighting] ?? 0) / Double(leqCount)) + calibrationOffset
            s.leqSeconds = Double(leqCount) / sampleRate
        }
        s.sequenceActive = sequenceActive
        s.segmentInProgress = segmentStart != nil
        if segmentCount > 0, segmentStart != nil {
            s.currentSegmentLevel = db(segmentSum / Double(segmentCount)) + calibrationOffset
        }
        s.readings = readings
        return s
    }

    /// Detects pink-noise bursts on the C-weighted fast level and records one Leq per burst.
    private func updateSequence(blockSumC: Double, blockCount: Int) {
        guard sequenceActive else { return }
        let fastC = db(meanSquareFast[.c]) + calibrationOffset
        let now = processedSeconds

        if let start = segmentStart {
            // Skip the first 0.5 s (speaker/room settling) and integrate.
            if now - start > 0.5 {
                segmentSum += blockSumC
                segmentCount += blockCount
            }
            if fastC < gateThreshold - 3 {
                if gateBelowSince == nil { gateBelowSince = now }
                if now - gateBelowSince! > 0.3 {
                    // Segment ended. Drop the last 0.3 s worth of blocks is unnecessary: the gate
                    // reacts within 125 ms and the decay is excluded by the threshold.
                    if segmentCount > 0 {
                        let index = readings.count
                        let names = layout.channels
                        let name = index < names.count ? names[index] : (index == names.count ? "All" : "Extra \(index - names.count)")
                        readings.append(ChannelReading(id: index, name: name,
                                                       leq: db(segmentSum / Double(segmentCount)) + calibrationOffset,
                                                       duration: now - start))
                    }
                    segmentStart = nil
                    segmentSum = 0
                    segmentCount = 0
                    gateBelowSince = nil
                    gateAboveSince = nil
                    onUpdate?(makeSnapshot())
                }
            } else {
                gateBelowSince = nil
            }
        } else {
            if fastC > gateThreshold {
                if gateAboveSince == nil { gateAboveSince = now }
                if now - gateAboveSince! > 0.2 {
                    segmentStart = now - 0.2
                    segmentSum = 0
                    segmentCount = 0
                    gateBelowSince = nil
                }
            } else {
                gateAboveSince = nil
            }
        }
    }
}
