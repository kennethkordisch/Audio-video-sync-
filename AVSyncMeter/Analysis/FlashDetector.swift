import Foundation

/// Finds the onset of full-screen flashes in a stream of per-frame luminance samples.
///
/// Onset is defined as the moment the luminance crosses halfway between the dark
/// baseline and the flash peak, linearly interpolated between the two camera frames
/// that straddle the crossing. Because the camera samples independently of the display's
/// refresh, this recovers the display's switching instant to a fraction of a camera frame.
/// (Prototyped as `flash_onsets` in tools/validate_pattern.py.)
struct FlashDetector {
    struct Sample {
        let time: Double
        let luma: Double
    }

    enum Event {
        case none
        /// A rise above threshold was seen on this frame.
        case started
        /// The flash ended; `onset` is the interpolated half-maximum crossing time.
        case completed(onset: Double, peakContrast: Double)
    }

    /// Luminance (0...255) above the baseline needed to trigger before any flash has been learned.
    var minContrast: Double = 12
    /// A "flash" longer than this is treated as a scene change and re-baselines instead.
    var maxFlashDuration: Double = 0.5
    /// Ignore new triggers this long after a flash ends.
    var refractory: Double = 0.3
    /// How quickly the baseline follows a slowly brightening scene (seconds).
    var baselineRiseTimeConstant: Double = 4.0

    private(set) var baseline: Double?
    private(set) var learnedContrast: Double?
    private(set) var isInFlash = false

    private var buffer: [Sample] = []
    private let capacity = 512
    private var flashStartIndex = 0
    private var flashStartTime = 0.0
    private var flashPeak = 0.0
    private var refractoryUntil = -Double.infinity
    private var lastTime: Double?

    mutating func reset() {
        self = FlashDetector(minContrast: minContrast,
                             maxFlashDuration: maxFlashDuration,
                             refractory: refractory,
                             baselineRiseTimeConstant: baselineRiseTimeConstant)
    }

    /// Forget the baseline (call when the region of interest changes).
    mutating func rebaseline() {
        baseline = nil
        isInFlash = false
    }

    mutating func add(time: Double, luma: Double) -> Event {
        buffer.append(Sample(time: time, luma: luma))
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        guard let base = baseline else {
            baseline = luma
            trimBuffer()
            return .none
        }

        if isInFlash {
            flashPeak = max(flashPeak, luma)
            let contrast = flashPeak - base
            let ended = (luma - base) < 0.3 * contrast
            let tooLong = time - flashStartTime > maxFlashDuration
            guard ended || tooLong else { return .none }

            isInFlash = false
            refractoryUntil = time + refractory
            if tooLong {
                // The scene got brighter and stayed that way: adopt it as the new baseline.
                baseline = luma
                trimBuffer()
                return .none
            }

            let half = base + 0.5 * contrast
            var k = max(flashStartIndex, 1)
            while k < buffer.count && buffer[k].luma < half { k += 1 }
            guard k < buffer.count else { trimBuffer(); return .none }
            let a = buffer[k - 1]
            let b = buffer[k]
            var onset = b.time
            if b.luma > a.luma {
                let frac = (half - a.luma) / (b.luma - a.luma)
                onset = a.time + min(1, max(0, frac)) * (b.time - a.time)
            }
            learnedContrast = learnedContrast.map { 0.7 * $0 + 0.3 * contrast } ?? contrast
            trimBuffer()
            return .completed(onset: onset, peakContrast: contrast)
        }

        // Idle: track the baseline. Fall immediately, rise slowly.
        if luma < base {
            baseline = luma
        } else if dt > 0 {
            let alpha = 1 - exp(-dt / baselineRiseTimeConstant)
            baseline = base + alpha * (luma - base)
        }
        trimBuffer()

        guard time >= refractoryUntil else { return .none }
        var threshold = minContrast
        if let learned = learnedContrast {
            threshold = max(minContrast, 0.3 * learned)
        }
        if luma - base > threshold {
            isInFlash = true
            flashStartIndex = buffer.count - 1
            flashStartTime = time
            flashPeak = luma
            return .started
        }
        return .none
    }

    private mutating func trimBuffer() {
        guard !isInFlash, buffer.count > capacity else { return }
        buffer.removeFirst(buffer.count - capacity)
    }
}
