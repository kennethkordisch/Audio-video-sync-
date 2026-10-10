import Foundation

/// Detects the onset of the test pattern's tone bursts in a mono audio stream and, when more
/// than one frequency is configured (channel-ID patterns: left = f, right = 1.6 f), tells which
/// band each burst was in.
///
/// Pipeline per band: 2nd-order band-pass biquad -> peak-follower envelope. The adaptive noise
/// floor and threshold work on the loudest band. An onset is the sample where that envelope
/// first exceeds the threshold (so the direct sound wins over room echoes); the band is decided
/// a few ms later, when the envelopes have separated.
struct BeepDetector {
    struct Onset {
        let time: Double
        /// Index into `frequencies`.
        let band: Int
    }

    var frequencies: [Double] = [TestPattern.toneFrequency]
    var q: Double = 10
    /// Envelope must exceed noiseFloor * attackRatio ...
    var attackRatio: Double = 6
    /// ... and this absolute level (full scale = 1.0).
    var minLevel: Double = 0.002
    var refractory: Double = 0.3
    var floorTimeConstant: Double = 0.5
    var envelopeRelease: Double = 0.02
    /// Seconds of audio to learn the noise floor before any detection is allowed.
    var warmup: Double = 0.3
    /// Seconds after the threshold crossing before the band is decided.
    var classifyDelay: Double = 0.004

    private struct Band {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var envelope = 0.0
    }

    private var sampleRate: Double = 0
    private var bands: [Band] = []
    private var releaseCoefficient = 0.0
    private var noiseFloorEstimate = 0.0
    private var floorAlpha = 0.0
    private var lastOnset = -Double.infinity
    private var processedSeconds = 0.0
    private var pending: (time: Double, samplesLeft: Int)?

    /// Peak envelope (loudest band) in the last processed chunk, for level meters.
    private(set) var level: Double = 0
    private(set) var noiseFloor: Double = 0
    private(set) var lastBand: Int?

    mutating func reset() {
        self = BeepDetector(frequencies: frequencies, q: q, attackRatio: attackRatio,
                            minLevel: minLevel, refractory: refractory,
                            floorTimeConstant: floorTimeConstant,
                            envelopeRelease: envelopeRelease, warmup: warmup,
                            classifyDelay: classifyDelay)
    }

    private mutating func configure(sampleRate sr: Double) {
        sampleRate = sr
        bands = frequencies.map { f in
            // RBJ constant-skirt band-pass.
            var band = Band()
            let w0 = 2 * Double.pi * f / sr
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            band.b0 = (sin(w0) / 2) / a0
            band.b1 = 0
            band.b2 = (-sin(w0) / 2) / a0
            band.a1 = (-2 * cos(w0)) / a0
            band.a2 = (1 - alpha) / a0
            return band
        }
        releaseCoefficient = exp(-1.0 / (envelopeRelease * sr))
        floorAlpha = 1.0 - exp(-1.0 / (floorTimeConstant * sr))
        pending = nil
    }

    /// Feeds a chunk whose first sample is at `startTime` (seconds, capture clock).
    mutating func process(_ samples: [Float], sampleRate sr: Double, startTime: Double) -> [Onset] {
        if sr != sampleRate || bands.count != frequencies.count { configure(sampleRate: sr) }
        var onsets: [Onset] = []
        var peak = 0.0
        let invRate = 1.0 / sr
        let classifySamples = max(1, Int(classifyDelay * sr))

        for (i, s) in samples.enumerated() {
            let xn = Double(s)
            var maxEnvelope = 0.0
            for b in bands.indices {
                var band = bands[b]
                let yn = band.b0 * xn + band.b1 * band.x1 + band.b2 * band.x2 - band.a1 * band.y1 - band.a2 * band.y2
                band.x2 = band.x1; band.x1 = xn
                band.y2 = band.y1; band.y1 = yn
                let a = abs(yn)
                band.envelope = a > band.envelope ? a : band.envelope * releaseCoefficient
                bands[b] = band
                if band.envelope > maxEnvelope { maxEnvelope = band.envelope }
            }
            if maxEnvelope > peak { peak = maxEnvelope }

            let t = startTime + Double(i) * invRate
            if var candidate = pending {
                candidate.samplesLeft -= 1
                if candidate.samplesLeft <= 0 {
                    var best = 0
                    for b in bands.indices where bands[b].envelope > bands[best].envelope { best = b }
                    onsets.append(Onset(time: candidate.time, band: best))
                    lastBand = best
                    pending = nil
                } else {
                    pending = candidate
                }
                continue
            }

            if processedSeconds < warmup {
                noiseFloorEstimate += floorAlpha * (maxEnvelope - noiseFloorEstimate)
            } else if t - lastOnset > refractory {
                let threshold = max(minLevel, noiseFloorEstimate * attackRatio)
                if maxEnvelope > threshold {
                    pending = (t, classifySamples)
                    lastOnset = t
                } else {
                    noiseFloorEstimate += floorAlpha * (maxEnvelope - noiseFloorEstimate)
                }
            }
        }
        processedSeconds += Double(samples.count) * invRate
        level = peak
        noiseFloor = noiseFloorEstimate
        return onsets
    }
}
