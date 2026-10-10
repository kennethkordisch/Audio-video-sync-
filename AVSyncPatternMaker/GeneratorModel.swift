import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class GeneratorModel {
    var spec = PatternSpec()
    var allFrameRates = false
    var outputFolder: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    var alsoDNxHR = false
    var dnxFlavour: DNxHRFlavour = .lb
    let ffmpeg = FFmpegExporter.locate()
    var ffmpegURL: URL? { ffmpeg?.url }

    var ffmpegDescription: String {
        guard let ffmpeg else { return "not available" }
        switch ffmpeg.source {
        case .bundled: return "bundled with the app"
        case .system: return ffmpeg.url.path
        }
    }

    var selectedPreset: Preset?

    // Pink-noise calibration file
    var pinkSpec = PinkNoiseSpec()
    var pinkWriteWAV = true
    var pinkWriteMovie = true

    func generatePink() {
        guard !isRunning, pinkWriteWAV || pinkWriteMovie else { return }
        isRunning = true
        progress = 0
        log.removeAll()
        outputs.removeAll()
        let spec = pinkSpec
        let video = self.spec
        let folder = outputFolder
        let wav = pinkWriteWAV, movie = pinkWriteMovie
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var produced: [URL] = []
            var failure: String?
            let writer = PinkNoiseWriter(spec: spec, video: video)
            let steps = (wav ? 1.0 : 0) + (movie ? 1.0 : 0)
            var done = 0.0
            if wav {
                let url = folder.appendingPathComponent("\(spec.baseName).wav")
                await self?.report("Writing \(url.lastPathComponent)", progress: 0)
                do {
                    try writer.writeWAV(to: url, progress: { p in
                        let overall = (done + p) / steps
                        Task { @MainActor [weak self] in self?.progress = overall }
                    }, isCancelled: { Task.isCancelled })
                    produced.append(url)
                    await self?.append("Wrote \(url.lastPathComponent)")
                } catch { failure = error.localizedDescription }
                done += 1
            }
            if movie, failure == nil, !Task.isCancelled {
                let url = folder.appendingPathComponent("\(spec.baseName).mov")
                await self?.report("Writing \(url.lastPathComponent)", progress: done / steps)
                do {
                    try writer.writeMovie(to: url, progress: { p in
                        let overall = (done + p) / steps
                        Task { @MainActor [weak self] in self?.progress = overall }
                    }, isCancelled: { Task.isCancelled })
                    produced.append(url)
                    await self?.append("Wrote \(url.lastPathComponent)")
                } catch { failure = error.localizedDescription }
            }
            let cancelled = Task.isCancelled
            await self?.finish(outputs: produced, failure: failure, cancelled: cancelled)
        }
    }

    func applyPreset(_ preset: Preset) {
        var dnx = alsoDNxHR
        var flavour = dnxFlavour
        var all = allFrameRates
        preset.apply(&spec, &dnx, &flavour, &all)
        alsoDNxHR = dnx && ffmpeg != nil
        dnxFlavour = flavour
        allFrameRates = all
        selectedPreset = preset
    }

    var isRunning = false
    var progress = 0.0
    var status = "Ready"
    var log: [String] = []
    var outputs: [URL] = []

    private var task: Task<Void, Never>?

    var estimatedFileSizeText: String {
        let seconds = spec.durationSeconds
        let pixels = Double(spec.resolution.width * spec.resolution.height) / (1920 * 1080)
        let fpsFactor = spec.frameRate.fps / 24
        // Rough Mb/s at 1080p24 for mostly-black content; scaled by pixels and frame rate.
        let videoMbps: Double
        switch spec.videoCodec {
        case .proResProxy: videoMbps = 45
        case .proResLT: videoMbps = 100
        case .proRes422: videoMbps = 145
        case .proResHQ: videoMbps = 220
        case .h264, .hevc: videoMbps = 6
        }
        let audioMbps = spec.audioFormat == .aac ? 0.256 : (spec.audioFormat == .pcm24 ? 2.3 : 1.5)
        let megabytes = (videoMbps * pixels * fpsFactor + audioMbps) * seconds / 8
        let count = allFrameRates ? FrameRate.all.count : 1
        if megabytes * Double(count) > 1024 {
            return String(format: "about %.1f GB%@", megabytes * Double(count) / 1024, count > 1 ? " total" : "")
        }
        return String(format: "about %.0f MB%@", megabytes * Double(count), count > 1 ? " total" : "")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func revealOutputs() {
        guard !outputs.isEmpty else {
            NSWorkspace.shared.open(outputFolder)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }

    func cancel() {
        task?.cancel()
    }

    func generate() {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        log.removeAll()
        outputs.removeAll()

        let rates = allFrameRates ? FrameRate.all : [spec.frameRate]
        let baseSpec = spec
        let folder = outputFolder
        let dnx = alsoDNxHR ? (ffmpegURL, dnxFlavour) : nil

        task = Task.detached(priority: .userInitiated) { [weak self] in
            var produced: [URL] = []
            var failure: String?
            for (index, rate) in rates.enumerated() {
                if Task.isCancelled { break }
                var fileSpec = baseSpec
                fileSpec.frameRate = rate
                let url = folder.appendingPathComponent(fileSpec.fileName)
                await self?.report("Rendering \(fileSpec.fileName)", progress: Double(index) / Double(rates.count))
                let writer = PatternWriter(spec: fileSpec, outputURL: url)
                do {
                    try writer.write(progress: { p in
                        let overall = (Double(index) + p) / Double(rates.count)
                        Task { @MainActor [weak self] in self?.progress = overall }
                    }, isCancelled: { Task.isCancelled })
                    produced.append(url)
                    await self?.append("Wrote \(url.lastPathComponent)")
                } catch {
                    failure = error.localizedDescription
                    await self?.append("Failed \(url.lastPathComponent): \(error.localizedDescription)")
                    break
                }

                if let dnx, let ffmpeg = dnx.0 {
                    let flavour = dnx.1
                    let mxf = folder.appendingPathComponent("\(fileSpec.baseName)_\(flavour.fileTag).mxf")
                    await self?.report("Transcoding to \(mxf.lastPathComponent) with ffmpeg", progress: nil)
                    do {
                        try FFmpegExporter.transcodeToDNxHR(source: url, destination: mxf, flavour: flavour, ffmpeg: ffmpeg)
                        produced.append(mxf)
                        await self?.append("Wrote \(mxf.lastPathComponent)")
                    } catch {
                        await self?.append("DNxHR failed: \(error.localizedDescription)")
                    }
                }
            }
            let cancelled = Task.isCancelled
            await self?.finish(outputs: produced, failure: failure, cancelled: cancelled)
        }
    }

    private func report(_ message: String, progress value: Double?) {
        status = message
        if let value { progress = value }
        log.append(message)
    }

    private func append(_ message: String) {
        log.append(message)
    }

    private func finish(outputs produced: [URL], failure: String?, cancelled: Bool) {
        outputs = produced
        isRunning = false
        progress = failure == nil && !cancelled ? 1 : progress
        if cancelled {
            status = "Cancelled"
        } else if let failure {
            status = "Failed: \(failure)"
        } else {
            status = "Done: \(produced.count) file\(produced.count == 1 ? "" : "s") in \(outputFolder.lastPathComponent)"
        }
    }
}
