import Foundation

/// Describes the bundled test pattern. These values mirror tools/make_test_pattern.sh;
/// regenerate the file and update both if you change them.
enum TestPattern {
    static let resourceName = "avsync_1080p60"
    static let resourceExtension = "mp4"

    /// Seconds between flash/beep events.
    static let period: TimeInterval = 2.0
    /// Time of the first event.
    static let leadIn: TimeInterval = 1.0
    /// Full-frame white duration (3 frames at 60 fps).
    static let flashDuration: TimeInterval = 0.05
    static let toneFrequency: Double = 1000
    static let toneDuration: TimeInterval = 0.05
    static let frameRate: Double = 60

    static var url: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }
}
