import Foundation

/// One of the frame rates the test pattern is rendered at.
struct PatternFrameRate: Identifiable, Hashable {
    let fps: Double
    let label: String
    let fileSuffix: String

    var id: Double { fps }
    var frameDuration: TimeInterval { 1 / fps }
}

/// Describes the bundled test patterns. These values mirror tools/make_test_pattern.sh;
/// regenerate the files and update both if you change them.
enum TestPattern {
    static let frameRates: [PatternFrameRate] = [
        PatternFrameRate(fps: 24000.0 / 1001.0, label: "23.976", fileSuffix: "2398"),
        PatternFrameRate(fps: 24, label: "24", fileSuffix: "24"),
        PatternFrameRate(fps: 25, label: "25", fileSuffix: "25"),
        PatternFrameRate(fps: 30000.0 / 1001.0, label: "29.97", fileSuffix: "2997"),
        PatternFrameRate(fps: 30, label: "30", fileSuffix: "30"),
        PatternFrameRate(fps: 50, label: "50", fileSuffix: "50"),
        PatternFrameRate(fps: 60000.0 / 1001.0, label: "59.94", fileSuffix: "5994"),
        PatternFrameRate(fps: 60, label: "60", fileSuffix: "60"),
    ]

    static var defaultFrameRate: PatternFrameRate { frameRates[0] }

    /// The listed frame rate closest to `fps` (settings store the fps as a Double).
    static func frameRate(matching fps: Double) -> PatternFrameRate {
        frameRates.min { abs($0.fps - fps) < abs($1.fps - fps) } ?? defaultFrameRate
    }

    /// Nominal seconds between events; the file rounds this to whole frames.
    static let nominalPeriod: TimeInterval = 2.0
    /// Nominal time of the first event; the file rounds this to whole frames.
    static let nominalLeadIn: TimeInterval = 1.0
    static let toneFrequency: Double = 1000
    static let toneDuration: TimeInterval = 0.05
    /// Channel-ID patterns alternate left = toneFrequency and right = toneFrequency * this ratio.
    static let channelIDRatio: Double = 1.6
    static var rightToneFrequency: Double { toneFrequency * channelIDRatio }

    static func periodFrames(_ rate: PatternFrameRate) -> Int {
        Int((nominalPeriod * rate.fps).rounded())
    }

    /// 2 white frames at 30 fps and below, 3 at 50 fps and above.
    static func flashFrames(_ rate: PatternFrameRate) -> Int {
        rate.fps <= 31 ? 2 : 3
    }

    static func fileName(for rate: PatternFrameRate) -> String {
        "avsync_1080p\(rate.fileSuffix).mp4"
    }

    static func url(for rate: PatternFrameRate) -> URL? {
        Bundle.main.url(forResource: "avsync_1080p\(rate.fileSuffix)", withExtension: "mp4")
    }
}
