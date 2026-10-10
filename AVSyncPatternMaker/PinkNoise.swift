import AVFoundation
import Foundation

/// Speaker layouts for pink-noise calibration files. Channel order matches the iOS app.
enum PinkLayout: String, CaseIterable, Identifiable {
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

    var longNames: [String] {
        switch self {
        case .stereo: return ["LEFT", "RIGHT"]
        case .threeOne: return ["LEFT", "RIGHT", "CENTER", "LFE"]
        case .fiveOne: return ["LEFT", "RIGHT", "CENTER", "LFE", "LEFT SURROUND", "RIGHT SURROUND"]
        case .sevenOne: return ["LEFT", "RIGHT", "CENTER", "LFE", "LEFT SIDE SURROUND", "RIGHT SIDE SURROUND",
                                "LEFT REAR SURROUND", "RIGHT REAR SURROUND"]
        }
    }

    var channelCount: Int { channels.count }
    var lfeIndex: Int? { channels.firstIndex(of: "LFE") }

    /// Core Audio layout tag with the same channel order.
    var layoutTag: AudioChannelLayoutTag {
        switch self {
        case .stereo: return kAudioChannelLayoutTag_Stereo
        case .threeOne: return kAudioChannelLayoutTag_DVD_10          // L R C LFE
        case .fiveOne: return kAudioChannelLayoutTag_MPEG_5_1_A       // L R C LFE Ls Rs
        case .sevenOne: return kAudioChannelLayoutTag_MPEG_7_1_C      // L R C LFE Ls Rs Rls Rrs
        }
    }

    var fileTag: String {
        switch self {
        case .stereo: return "stereo"
        case .threeOne: return "3_1"
        case .fiveOne: return "5_1"
        case .sevenOne: return "7_1"
        }
    }
}

struct PinkNoiseSpec {
    var layout: PinkLayout = .fiveOne
    var segmentSeconds: Double = 10
    var gapSeconds: Double = 1
    var leadInSeconds: Double = 2
    /// RMS level of each channel's pink noise.
    var levelDBFS: Double = -20
    /// Band-limit the LFE channel to 120 Hz (2nd-order Butterworth).
    var lfeLowPass = true
    /// Append one segment with all channels at once.
    var includeAllSegment = false
    var repeats: Int = 1
    var sampleRate: Double = 48000

    struct Segment {
        /// nil = all channels.
        let channel: Int?
        let start: Double
        let end: Double
        let title: String
    }

    var segments: [Segment] {
        var result: [Segment] = []
        var t = leadInSeconds
        for _ in 0..<max(1, repeats) {
            for (i, name) in layout.longNames.enumerated() {
                result.append(Segment(channel: i, start: t, end: t + segmentSeconds, title: name))
                t += segmentSeconds + gapSeconds
            }
        }
        if includeAllSegment {
            result.append(Segment(channel: nil, start: t, end: t + segmentSeconds, title: "ALL CHANNELS"))
            t += segmentSeconds + gapSeconds
        }
        return result
    }

    var durationSeconds: Double { (segments.last?.end ?? leadInSeconds) + gapSeconds }

    func segment(at time: Double) -> Segment? {
        segments.first { time >= $0.start && time < $0.end }
    }

    var baseName: String {
        String(format: "pink_%@_%ddb_%ds", layout.fileTag, Int(-levelDBFS.rounded()), Int(segmentSeconds.rounded()))
    }
}

/// Paul Kellet's "refined" pink filter on white noise, one independent stream per channel,
/// scaled to the requested RMS. The LFE channel is optionally low-passed at 120 Hz.
struct PinkNoiseGenerator {
    private struct Stream {
        var seed: UInt64
        var b = [Double](repeating: 0, count: 7)
        var gain = 1.0
        var lp: Biquad?

        mutating func white() -> Double {
            // xorshift64*
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            let v = seed &* 2685821657736338717
            return Double(v >> 11) / Double(1 << 53) * 2 - 1
        }

        mutating func next() -> Double {
            let w = white()
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520
            b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522
            b[5] = -0.7616 * b[5] - w * 0.0168980
            var pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            if var filter = lp {
                pink = filter.process(pink)
                lp = filter
            }
            return pink * gain
        }
    }

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        static func lowPass(frequency: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let cosw = cos(w0)
            let a0 = 1 + alpha
            return Biquad(b0: (1 - cosw) / 2 / a0, b1: (1 - cosw) / a0, b2: (1 - cosw) / 2 / a0,
                          a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    let spec: PinkNoiseSpec
    private var streams: [Stream]
    private let segments: [PinkNoiseSpec.Segment]

    init(spec: PinkNoiseSpec) {
        self.spec = spec
        segments = spec.segments
        let targetRMS = pow(10, spec.levelDBFS / 20)
        streams = (0..<spec.layout.channelCount).map { i in
            var stream = Stream(seed: 0x9E3779B97F4A7C15 &+ UInt64(i) &* 0xBF58476D1CE4E5B9)
            if spec.lfeLowPass, i == spec.layout.lfeIndex {
                stream.lp = Biquad.lowPass(frequency: 120, sampleRate: spec.sampleRate)
            }
            // Measure this stream's natural RMS over two seconds and scale to the target.
            var sum = 0.0
            let n = Int(2 * spec.sampleRate)
            for _ in 0..<n { let v = stream.next(); sum += v * v }
            let rms = (sum / Double(n)).squareRoot()
            stream.gain = rms > 0 ? targetRMS / rms : 1
            return stream
        }
    }

    /// Interleaved Float32 samples for [startSample, startSample + count).
    mutating func samples(from startSample: Int, count: Int) -> [Float] {
        let channels = spec.layout.channelCount
        var out = [Float](repeating: 0, count: count * channels)
        let invRate = 1 / spec.sampleRate
        var activeSegmentIndex = 0
        for n in 0..<count {
            let t = Double(startSample + n) * invRate
            while activeSegmentIndex < segments.count && t >= segments[activeSegmentIndex].end { activeSegmentIndex += 1 }
            let active = activeSegmentIndex < segments.count && t >= segments[activeSegmentIndex].start ? segments[activeSegmentIndex] : nil
            for c in 0..<channels {
                // Keep every stream running so the noise is continuous when its channel is on.
                let v = streams[c].next()
                guard let active, active.channel == nil || active.channel == c else { continue }
                out[n * channels + c] = Float(max(-0.999, min(0.999, v)))
            }
        }
        return out
    }
}
