import Foundation

/// Optional DNxHR MXF output through a locally installed ffmpeg (Homebrew or MacPorts).
enum FFmpegExporter {
    static let candidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    static func locate() -> URL? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
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
