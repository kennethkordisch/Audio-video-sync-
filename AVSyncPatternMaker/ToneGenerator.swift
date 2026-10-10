import Foundation

/// Produces the stereo tone-burst track sample by sample. Bursts start exactly on the event's
/// first white frame; a 0.5 ms linear fade in/out avoids speaker clicks.
struct ToneGenerator {
    let spec: PatternSpec
    private let eventStarts: [Int]
    private let burstSamples: Int
    private let rampSamples: Int

    init(spec: PatternSpec) {
        self.spec = spec
        eventStarts = spec.eventStartSamples
        burstSamples = Int((spec.toneDurationSeconds * spec.sampleRate).rounded())
        rampSamples = max(1, Int((0.0005 * spec.sampleRate).rounded()))
    }

    /// Interleaved stereo Float32 samples for [startSample, startSample + count).
    func samples(from startSample: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count * 2)
        let end = startSample + count
        for (eventIndex, burstStart) in eventStarts.enumerated() {
            let burstEnd = burstStart + burstSamples
            guard burstEnd > startSample, burstStart < end else { continue }
            let left: Bool
            let right: Bool
            let frequency: Double
            switch spec.channelMode {
            case .both:
                left = true; right = true
                frequency = spec.toneFrequency
            case .alternate:
                left = eventIndex % 2 == 0; right = !left
                frequency = left ? spec.toneFrequency : spec.rightToneFrequency
            }
            let omega = 2 * Double.pi * frequency / spec.sampleRate
            for n in max(burstStart, startSample)..<min(burstEnd, end) {
                let k = n - burstStart
                var gain = spec.toneAmplitude
                if k < rampSamples { gain *= Double(k) / Double(rampSamples) }
                let remaining = burstSamples - k
                if remaining < rampSamples { gain *= Double(remaining) / Double(rampSamples) }
                // Phase referenced to absolute time so the burst starts at a zero crossing.
                let value = Float(gain * sin(omega * Double(n - burstStart)))
                let i = (n - startSample) * 2
                if left { out[i] = value }
                if right { out[i + 1] = value }
            }
        }
        return out
    }
}
