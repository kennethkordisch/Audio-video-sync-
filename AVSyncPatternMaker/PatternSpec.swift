import AVFoundation
import Foundation

/// A frame rate as an exact rational.
struct FrameRate: Identifiable, Hashable {
    let numerator: Int32
    let denominator: Int32
    let label: String
    let fileSuffix: String

    var id: String { label }
    var fps: Double { Double(numerator) / Double(denominator) }
    var frameDuration: CMTime { CMTime(value: CMTimeValue(denominator), timescale: numerator) }
    /// Nominal integer rate used for timecode frame counts.
    var timecodeBase: Int { Int(fps.rounded()) }

    static let all: [FrameRate] = [
        FrameRate(numerator: 24000, denominator: 1001, label: "23.976", fileSuffix: "2398"),
        FrameRate(numerator: 24, denominator: 1, label: "24", fileSuffix: "24"),
        FrameRate(numerator: 25, denominator: 1, label: "25", fileSuffix: "25"),
        FrameRate(numerator: 30000, denominator: 1001, label: "29.97", fileSuffix: "2997"),
        FrameRate(numerator: 30, denominator: 1, label: "30", fileSuffix: "30"),
        FrameRate(numerator: 50, denominator: 1, label: "50", fileSuffix: "50"),
        FrameRate(numerator: 60000, denominator: 1001, label: "59.94", fileSuffix: "5994"),
        FrameRate(numerator: 60, denominator: 1, label: "60", fileSuffix: "60"),
    ]
}

struct Resolution: Identifiable, Hashable {
    let width: Int
    let height: Int
    let label: String
    var id: String { label }

    static let all: [Resolution] = [
        Resolution(width: 1280, height: 720, label: "1280 x 720 (HD 720p)"),
        Resolution(width: 1920, height: 1080, label: "1920 x 1080 (HD 1080p)"),
        Resolution(width: 2048, height: 1080, label: "2048 x 1080 (DCI 2K)"),
        Resolution(width: 3840, height: 2160, label: "3840 x 2160 (UHD)"),
        Resolution(width: 4096, height: 2160, label: "4096 x 2160 (DCI 4K)"),
    ]
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case proResProxy = "ProRes 422 Proxy"
    case proResLT = "ProRes 422 LT"
    case proRes422 = "ProRes 422"
    case proResHQ = "ProRes 422 HQ"
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"

    var id: String { rawValue }

    var avCodec: AVVideoCodecType {
        switch self {
        case .proResProxy: return .proRes422Proxy
        case .proResLT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proResHQ: return .proRes422HQ
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    var isProRes: Bool {
        switch self {
        case .h264, .hevc: return false
        default: return true
        }
    }

    var fileTag: String {
        switch self {
        case .proResProxy: return "prores_proxy"
        case .proResLT: return "prores_lt"
        case .proRes422: return "prores_422"
        case .proResHQ: return "prores_hq"
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case pcm24 = "PCM 24-bit"
    case pcm16 = "PCM 16-bit"
    case aac = "AAC 256 kb/s"
    var id: String { rawValue }
    var isPCM: Bool { self != .aac }
}

enum ChannelMode: String, CaseIterable, Identifiable {
    case both = "Both channels"
    case alternate = "Alternate L / R per event"
    var id: String { rawValue }
}

enum DNxHRFlavour: String, CaseIterable, Identifiable {
    case lb = "DNxHR LB"
    case sq = "DNxHR SQ"
    case hq = "DNxHR HQ"
    var id: String { rawValue }
    var ffmpegProfile: String {
        switch self {
        case .lb: return "dnxhr_lb"
        case .sq: return "dnxhr_sq"
        case .hq: return "dnxhr_hq"
        }
    }
    var fileTag: String {
        switch self {
        case .lb: return "dnxhr_lb"
        case .sq: return "dnxhr_sq"
        case .hq: return "dnxhr_hq"
        }
    }
}

/// Everything needed to render one pattern file.
struct PatternSpec {
    var frameRate: FrameRate = FrameRate.all[0]
    var resolution: Resolution = Resolution.all[1]
    var durationSeconds: Double = 60
    var videoCodec: VideoCodec = .proResProxy
    var audioFormat: AudioFormat = .pcm24
    var sampleRate: Double = 48000

    /// Nominal seconds between events (rounded to whole frames).
    var periodSeconds: Double = 2
    /// Nominal time of the first event (rounded to whole frames).
    var leadInSeconds: Double = 1
    var flashFrames: Int = 2
    var toneFrequency: Double = 1000
    var toneDurationMs: Double = 50
    var toneLevelDBFS: Double = -3
    var channelMode: ChannelMode = .both
    var showCaption = true
    var burnInTimecode = false

    // Derived frame grid. Events sit on whole frames; tone starts at the first white frame's time.
    var firstEventFrame: Int { Int((leadInSeconds * frameRate.fps).rounded()) }
    var periodFrames: Int { max(1, Int((periodSeconds * frameRate.fps).rounded())) }
    var totalFrames: Int { Int((durationSeconds * frameRate.fps).rounded()) }
    var toneAmplitude: Double { pow(10, toneLevelDBFS / 20) }
    var toneDurationSeconds: Double { toneDurationMs / 1000 }

    func eventIndex(forFrame frame: Int) -> Int? {
        guard frame >= firstEventFrame else { return nil }
        return (frame - firstEventFrame) / periodFrames
    }

    func isFlashFrame(_ frame: Int) -> Bool {
        guard frame >= firstEventFrame else { return false }
        return (frame - firstEventFrame) % periodFrames < flashFrames
    }

    /// Exact time of frame `frame` in seconds.
    func time(ofFrame frame: Int) -> Double {
        Double(frame) * Double(frameRate.denominator) / Double(frameRate.numerator)
    }

    /// First sample of each tone burst.
    var eventStartSamples: [Int] {
        var result: [Int] = []
        var frame = firstEventFrame
        while frame < totalFrames {
            result.append(Int((time(ofFrame: frame) * sampleRate).rounded()))
            frame += periodFrames
        }
        return result
    }

    var fileExtension: String {
        // MP4 cannot carry LPCM; ProRes belongs in QuickTime.
        (videoCodec.isProRes || audioFormat.isPCM) ? "mov" : "mp4"
    }

    var fileType: AVFileType { fileExtension == "mov" ? .mov : .mp4 }

    var baseName: String {
        "avsync_\(resolution.height)p\(frameRate.fileSuffix)_\(videoCodec.fileTag)"
    }

    var fileName: String { "\(baseName).\(fileExtension)" }

    func timecode(forFrame frame: Int) -> String {
        let base = frameRate.timecodeBase
        let ff = frame % base
        let totalSeconds = frame / base
        return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, ff)
    }
}
