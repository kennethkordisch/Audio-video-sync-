import Foundation

/// Detects the onset of the test pattern's tone bursts in a mono audio stream.
///
/// Pipeline: 2nd-order band-pass biquad centred on the tone -> peak-follower envelope ->
/// adaptive noise floor -> threshold crossing. The onset time is the sample at which the
/// envelope first exceeds the threshold, so the direct-path arrival wins over room echoes.
/// (Prototyped as `beep_onsets` in tools/validate_pattern.py.)
struct BeepDetector {
    var toneFrequency: Double = TestPattern.toneFrequency
    var q: Double = 8
    /// Envelope must exceed noiseFloor * attackRatio ...
    var attackRatio: Double = 6
    /// ... and this absolute level (full scale = 1.0).
    var minLevel: Double = 0.002
    var refractory: Double = 0.3
    var floorTimeConstant: Double = 0.5
    var envelopeRelease: Double = 0.02
    /// Seconds of audio to learn the noise floor before any detection is allowed.
    var warmup: Double = 0.3

    private var sampleRate: Double = 0
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    private var envelope = 0.0
    private var releaseCoefficient = 0.0
    private var noiseFloorEstimate = 0.0
    private var floorAlpha = 0.0
    private var lastOnset = -Double.infinity
    private var processedSeconds = 0.0

    /// Peak band-passed envelope in the last processed chunk (for level meters).
    private(set) var level: Double = 0
    private(set) var noiseFloor: Double = 0

    mutating func reset() {
        self = BeepDetector(toneFrequency: toneFrequency, q: q, attackRatio: attackRatio,
                            minLevel: minLevel, refractory: refractory,
                            floorTimeConstant: floorTimeConstant,
                            envelopeRelease: envelopeRelease, warmup: warmup)
    }

    private mutating func configure(sampleRate sr: Double) {
        sampleRate = sr
        // RBJ constant-skirt band-pass.
        let w0 = 2 * Double.pi * toneFrequency / sr
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = (sin(w0) / 2) / a0
        b1 = 0
        b2 = (-sin(w0) / 2) / a0
        a1 = (-2 * cos(w0)) / a0
        a2 = (1 - alpha) / a0
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
        envelope = 0
        releaseCoefficient = exp(-1.0 / (envelopeRelease * sr))
        floorAlpha = 1.0 - exp(-1.0 / (floorTimeConstant * sr))
    }

    /// Feeds a chunk whose first sample is at `startTime` (seconds, capture clock).
    /// Returns onset times found in this chunk.
    mutating func process(_ samples: [Float], sampleRate sr: Double, startTime: Double) -> [Double] {
        if sr != sampleRate { configure(sampleRate: sr) }
        var onsets: [Double] = []
        var peak = 0.0
        let invRate = 1.0 / sr
        for (i, s) in samples.enumerated() {
            let xn = Double(s)
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
            let a = abs(yn)
            envelope = a > envelope ? a : envelope * releaseCoefficient
            if envelope > peak { peak = envelope }

            let t = startTime + Double(i) * invRate
            if processedSeconds < warmup {
                noiseFloorEstimate += floorAlpha * (envelope - noiseFloorEstimate)
            } else if t - lastOnset > refractory {
                let threshold = max(minLevel, noiseFloorEstimate * attackRatio)
                if envelope > threshold {
                    onsets.append(t)
                    lastOnset = t
                } else {
                    noiseFloorEstimate += floorAlpha * (envelope - noiseFloorEstimate)
                }
            }
        }
        processedSeconds += Double(samples.count) * invRate
        level = peak
        noiseFloor = noiseFloorEstimate
        return onsets
    }
}
