import Foundation

/// IEC 61672 A- and C-weighting as cascades of bilinear-transformed first-order sections,
/// normalised to 0 dB at 1 kHz. Z = no weighting.
enum Weighting: String, CaseIterable, Identifiable {
    case a = "A"
    case c = "C"
    case z = "Z"
    var id: String { rawValue }
}

struct WeightingFilter {
    private struct Section {
        var b0 = 1.0, b1 = 0.0, a1 = 0.0
        var x1 = 0.0, y1 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 - a1 * y1
            x1 = x
            y1 = y
            return y
        }

        /// |H| at angular frequency w (radians/sample).
        func magnitude(at w: Double) -> Double {
            let zr = cos(w), zi = -sin(w)   // z^-1
            let nr = b0 + b1 * zr, ni = b1 * zi
            let dr = 1 + a1 * zr, di = a1 * zi
            return hypot(nr, ni) / hypot(dr, di)
        }
    }

    let weighting: Weighting
    private var sections: [Section] = []
    private var gain = 1.0

    init(weighting: Weighting, sampleRate: Double) {
        self.weighting = weighting
        let k = 2 * sampleRate
        func highPass(_ f: Double) -> Section {
            let w = 2 * Double.pi * f
            return Section(b0: k / (k + w), b1: -k / (k + w), a1: (w - k) / (k + w))
        }
        func lowPass(_ f: Double) -> Section {
            let w = 2 * Double.pi * f
            return Section(b0: w / (k + w), b1: w / (k + w), a1: (w - k) / (k + w))
        }
        switch weighting {
        case .a:
            sections = [highPass(20.598997), highPass(20.598997), highPass(107.65265), highPass(737.86223),
                        lowPass(12194.217), lowPass(12194.217)]
        case .c:
            sections = [highPass(20.598997), highPass(20.598997), lowPass(12194.217), lowPass(12194.217)]
        case .z:
            sections = []
        }
        let w1k = 2 * Double.pi * 1000 / sampleRate
        let response = sections.reduce(1.0) { $0 * $1.magnitude(at: w1k) }
        gain = response > 0 ? 1 / response : 1
    }

    mutating func process(_ x: Double) -> Double {
        var y = x
        for i in sections.indices { y = sections[i].process(y) }
        return y * gain
    }
}
