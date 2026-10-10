import Foundation

enum Acoustics {
    /// Speed of sound in air (m/s) for a temperature in degrees Celsius.
    /// Linear approximation, accurate to better than 0.1% between -20 and +40 C.
    static func speedOfSound(celsius: Double) -> Double {
        331.3 + 0.606 * celsius
    }

    /// Time for sound to travel `distanceMeters` (seconds).
    static func propagationDelay(distanceMeters: Double, celsius: Double) -> TimeInterval {
        guard distanceMeters > 0 else { return 0 }
        return distanceMeters / speedOfSound(celsius: celsius)
    }
}
