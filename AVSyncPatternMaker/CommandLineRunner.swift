import Foundation

/// Headless rendering:  AVSyncPatternMaker.app/Contents/MacOS/AVSyncPatternMaker --render [options]
///
///   --out DIR            output folder (default: current directory)
///   --fps 23.976|24|25|29.97|30|50|59.94|60|all   (default 23.976)
///   --duration SECONDS   (default 60)
///   --size WxH           1280x720 | 1920x1080 | 2048x1080 | 3840x2160 | 4096x2160 (default 1920x1080)
///   --codec proxy|lt|422|hq|h264|hevc             (default proxy)
///   --audio pcm24|pcm16|aac                        (default pcm24)
///   --period SECONDS     --flash FRAMES   --tone HZ   --tone-ms MS   --level DBFS
///   --channel-id         alternate L (tone) / R (1.6 x tone)
///   --no-caption         --timecode        --slate SECONDS
///   --dnxhr lb|sq|hq     also write DNxHR MXF with the bundled ffmpeg
///   --preset NAME        start from a preset (see Presets.swift), then apply other options
///
///   --pink stereo|3.1|5.1|7.1   render a pink-noise speaker-level sequence instead of the sync pattern
///   --segment SECONDS   --gap SECONDS   --pink-level DBFS   --repeats N   --all-segment   --no-lfe-lowpass
///   --wav-only | --mov-only     (default: both; the movie uses --fps/--size/--codec)
enum CommandLineRunner {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--render") else { return }
        exit(run(arguments: Array(args.dropFirst())))
    }

    static func run(arguments: [String]) -> Int32 {
        var spec = PatternSpec()
        var outDir = FileManager.default.currentDirectoryPath
        var allRates = false
        var dnx: DNxHRFlavour?
        var dnxOn = false
        var flavour = DNxHRFlavour.lb

        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }

        if let name = value(after: "--preset") {
            guard let preset = Preset.all.first(where: { $0.name.lowercased().hasPrefix(name.lowercased()) }) else {
                fputs("unknown preset '\(name)'. Available:\n" + Preset.all.map { "  \($0.name)" }.joined(separator: "\n") + "\n", stderr)
                return 2
            }
            preset.apply(&spec, &dnxOn, &flavour, &allRates)
            if dnxOn { dnx = flavour }
        }
        if let v = value(after: "--out") { outDir = v }
        if let v = value(after: "--fps") {
            if v == "all" { allRates = true }
            else if let rate = FrameRate.all.first(where: { $0.label == v || $0.fileSuffix == v }) { spec.frameRate = rate }
            else { fputs("unknown fps '\(v)'\n", stderr); return 2 }
        }
        if let v = value(after: "--duration"), let d = Double(v) { spec.durationSeconds = d }
        if let v = value(after: "--size") {
            guard let r = Resolution.all.first(where: { "\($0.width)x\($0.height)" == v }) else { fputs("unknown size '\(v)'\n", stderr); return 2 }
            spec.resolution = r
        }
        if let v = value(after: "--codec") {
            switch v {
            case "proxy": spec.videoCodec = .proResProxy
            case "lt": spec.videoCodec = .proResLT
            case "422": spec.videoCodec = .proRes422
            case "hq": spec.videoCodec = .proResHQ
            case "h264": spec.videoCodec = .h264
            case "hevc": spec.videoCodec = .hevc
            default: fputs("unknown codec '\(v)'\n", stderr); return 2
            }
        }
        if let v = value(after: "--audio") {
            switch v {
            case "pcm24": spec.audioFormat = .pcm24
            case "pcm16": spec.audioFormat = .pcm16
            case "aac": spec.audioFormat = .aac
            default: fputs("unknown audio '\(v)'\n", stderr); return 2
            }
        }
        if let v = value(after: "--period"), let d = Double(v) { spec.periodSeconds = d }
        if let v = value(after: "--flash"), let n = Int(v) { spec.flashFrames = n }
        if let v = value(after: "--tone"), let d = Double(v) { spec.toneFrequency = d }
        if let v = value(after: "--tone-ms"), let d = Double(v) { spec.toneDurationMs = d }
        if let v = value(after: "--level"), let d = Double(v) { spec.toneLevelDBFS = d }
        if let v = value(after: "--slate"), let d = Double(v) { spec.slateSeconds = d }
        if arguments.contains("--channel-id") { spec.channelMode = .alternate }
        if arguments.contains("--no-caption") { spec.showCaption = false }
        if arguments.contains("--timecode") { spec.burnInTimecode = true }
        if let v = value(after: "--dnxhr") {
            switch v {
            case "lb": dnx = .lb
            case "sq": dnx = .sq
            case "hq": dnx = .hq
            default: fputs("unknown dnxhr flavour '\(v)'\n", stderr); return 2
            }
        }

        let folder = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let layoutName = value(after: "--pink") {
            var pink = PinkNoiseSpec()
            guard let layout = PinkLayout.allCases.first(where: { $0.rawValue.lowercased() == layoutName.lowercased() }) else {
                fputs("unknown layout '\(layoutName)' (stereo, 3.1, 5.1, 7.1)\n", stderr); return 2
            }
            pink.layout = layout
            if let v = value(after: "--segment"), let d = Double(v) { pink.segmentSeconds = d }
            if let v = value(after: "--gap"), let d = Double(v) { pink.gapSeconds = d }
            if let v = value(after: "--pink-level"), let d = Double(v) { pink.levelDBFS = d }
            if let v = value(after: "--repeats"), let n = Int(v) { pink.repeats = n }
            if arguments.contains("--all-segment") { pink.includeAllSegment = true }
            if arguments.contains("--no-lfe-lowpass") { pink.lfeLowPass = false }
            let writer = PinkNoiseWriter(spec: pink, video: spec)
            do {
                if !arguments.contains("--mov-only") {
                    let url = folder.appendingPathComponent("\(pink.baseName).wav")
                    print("writing \(url.path)")
                    try writer.writeWAV(to: url, progress: { _ in }, isCancelled: { false })
                }
                if !arguments.contains("--wav-only") {
                    let url = folder.appendingPathComponent("\(pink.baseName).mov")
                    print("writing \(url.path)")
                    try writer.writeMovie(to: url, progress: { _ in }, isCancelled: { false })
                }
            } catch {
                fputs("failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
            print("done")
            return 0
        }

        let rates = allRates ? FrameRate.all : [spec.frameRate]
        let ffmpeg = FFmpegExporter.locate()
        if dnx != nil && ffmpeg == nil {
            fputs("warning: ffmpeg not available, skipping DNxHR\n", stderr)
        }

        for rate in rates {
            var fileSpec = spec
            fileSpec.frameRate = rate
            let url = folder.appendingPathComponent(fileSpec.fileName)
            print("rendering \(url.path)")
            var lastShown = -1
            do {
                try PatternWriter(spec: fileSpec, outputURL: url).write(progress: { p in
                    let percent = Int(p * 100)
                    if percent / 10 != lastShown / 10 {
                        lastShown = percent
                        print("  \(percent)%")
                    }
                }, isCancelled: { false })
            } catch {
                fputs("failed: \(error.localizedDescription)\n", stderr)
                return 1
            }
            if let dnx, let ffmpeg {
                let mxf = folder.appendingPathComponent("\(fileSpec.baseName)_\(dnx.fileTag).mxf")
                print("transcoding \(mxf.path)")
                do {
                    try FFmpegExporter.transcodeToDNxHR(source: url, destination: mxf, flavour: dnx, ffmpeg: ffmpeg.url)
                } catch {
                    fputs("dnxhr failed: \(error.localizedDescription)\n", stderr)
                    return 1
                }
            }
        }
        print("done")
        return 0
    }
}
