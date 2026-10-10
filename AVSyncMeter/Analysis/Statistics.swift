import Foundation

enum Statistics {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    /// Median absolute deviation: a robust spread estimate (about 0.67 sigma for normal data).
    static func mad(_ values: [Double]) -> Double? {
        guard let m = median(values) else { return nil }
        return median(values.map { abs($0 - m) })
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let m = mean(values) else { return nil }
        let ss = values.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(values.count - 1)).squareRoot()
    }
}
