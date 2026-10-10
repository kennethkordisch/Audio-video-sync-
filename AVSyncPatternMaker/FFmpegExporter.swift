import Foundation

/// DNxHR MXF output through ffmpeg: the copy bundled in the app by the "Bundle ffmpeg" build
/// phase (tools/bundle-ffmpeg.sh), or a locally installed one (Homebrew or MacPorts).
enum FFmpegExporter {
    enum Source {
        case bundled, system
    }

    static let candidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    static func locate() -> (url: URL, source: Source)? {
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, .bundled)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), .system)
        }
        return nil
    }

    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Transcodes a rendered pattern to DNxHR in OP1a MXF with 24-bit PCM. Blocking.
    static func transcodeToDNxHR(source: URL, destination: URL, flavour: DNxHRFlavour, ffmpeg: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "error",
            "-i", source.path,
            "-c:v", "dnxhd", "-profile:v", flavour.ffmpegProfile, "-pix_fmt", "yuv422p",
            "-c:a", "pcm_s24le", "-ar", "48000",
            "-f", "mxf", destination.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExportError(message: "ffmpeg exited with \(process.terminationStatus): \(text)")
        }
    }
}
