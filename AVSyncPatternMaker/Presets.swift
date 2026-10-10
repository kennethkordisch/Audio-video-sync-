import Foundation

/// Ready-made configurations for common jobs.
struct Preset: Identifiable, Hashable {
    let name: String
    let detail: String
    var id: String { name }

    /// Applies the preset to a spec and the DNxHR option. Returns (spec, alsoDNxHR, flavour, allRates).
    let apply: (inout PatternSpec, inout Bool, inout DNxHRFlavour, inout Bool) -> Void

    static func == (lhs: Preset, rhs: Preset) -> Bool { lhs.name == rhs.name }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    static let all: [Preset] = [
        Preset(name: "Avid 23.976 sync check",
               detail: "60 s, ProRes Proxy + DNxHR LB MXF, 24-bit PCM") { spec, dnx, flavour, all in
            spec = PatternSpec()
            spec.frameRate = FrameRate.all[0]
            spec.durationSeconds = 60
            spec.videoCodec = .proResProxy
            spec.audioFormat = .pcm24
            dnx = true; flavour = .lb; all = false
        },
        Preset(name: "Avid 23.976 drift, 30 min",
               detail: "1800 s, ProRes Proxy + DNxHR LB MXF, timecode burn-in") { spec, dnx, flavour, all in
            spec = PatternSpec()
            spec.frameRate = FrameRate.all[0]
            spec.durationSeconds = 1800
            spec.videoCodec = .proResProxy
            spec.audioFormat = .pcm24
            spec.burnInTimecode = true
            dnx = true; flavour = .lb; all = false
        },
        Preset(name: "Resolve 24 ProRes Proxy",
               detail: "60 s, ProRes Proxy, 24-bit PCM, 5 s bars/PLUGE slate") { spec, dnx, flavour, all in
            spec = PatternSpec()
            spec.frameRate = FrameRate.all[1]
            spec.durationSeconds = 60
            spec.videoCodec = .proResProxy
            spec.audioFormat = .pcm24
            spec.slateSeconds = 5
            dnx = false; all = false
        },
        Preset(name: "Broadcast 29.97 H.264",
               detail: "60 s MP4, H.264 + AAC, timecode burn-in") { spec, dnx, flavour, all in
            spec = PatternSpec()
            spec.frameRate = FrameRate.all[3]
            spec.durationSeconds = 60
            spec.videoCodec = .h264
            spec.audioFormat = .aac
            spec.burnInTimecode = true
            dnx = false; all = false
        },
        Preset(name: "Channel ID (L 1 kHz / R 1.6 kHz)",
               detail: "60 s ProRes Proxy, alternating left/right tones for per-channel sync") { spec, dnx, flavour, all in
            spec = PatternSpec()
            spec.durationSeconds = 60
            spec.videoCodec = .proResProxy
            spec.audioFormat = .pcm24
            spec.channelMode = .alternate
            dnx = false; all = false
        },
        Preset(name: "All rates, app bundle",
               detail: "8 x 60 s, H.264 + AAC MP4 (what the iOS app ships)") { spec, dnx, flavour, all in
            spec = PatternSpec()
            spec.durationSeconds = 60
            spec.videoCodec = .h264
            spec.audioFormat = .aac
            dnx = false; all = true
        },
    ]
}
