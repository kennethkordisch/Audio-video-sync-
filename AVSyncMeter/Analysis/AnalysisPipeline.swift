import CoreGraphics
import Foundation

/// Owns the detectors and the pairing logic, runs them on a serial queue, and publishes
/// snapshots for the UI.
final class AnalysisPipeline {
    struct Snapshot {
        var summary = SyncSummary.empty
        /// Most recent offsets (seconds), newest last.
        var recentOffsets: [Double] = []
        /// Every paired event, oldest first.
        var pairs: [SyncPair] = []
        var drift: DriftEstimate?
        var slips: [FrameSlip] = []
        var flashCount = 0
        var beepCount = 0
        var lumaLevel = 0.0
        var lumaBaseline: Double?
        var isInFlash = false
        var audioLevel = 0.0
        var audioNoiseFloor = 0.0
        var measuredFrameRate = 0.0
        /// Learned screen region, normalized to the camera frame (origin top-left).
        var screenRect: CGRect?
        /// Camera-based distance estimate (meters) and how many flashes contributed.
        var cameraDistance: Double?
        var cameraDistanceSamples = 0
        var hasIntrinsics = false

        static let empty = Snapshot()
    }

    var onUpdate: (@Sendable (Snapshot) -> Void)?

    private let queue = DispatchQueue(label: "AVSyncMeter.analysis", qos: .userInteractive)
    private var settings = AppSettings.Snapshot.load()
    private var flashDetector = FlashDetector()
    private var beepDetector = BeepDetector()
    private var analyzer = SyncAnalyzer()
    private var snapshot = Snapshot()

    private var screenRegion: CellRect?
    private var lastIdleFrame: LumaFrame?
    private var darkReference: LumaFrame?
    private var brightestFlashFrame: LumaFrame?
    private var distanceEstimates: [Double] = []
    private var lastFrameTime: Double?
    private var lastEmit: Double = 0

    func reset(settings: AppSettings.Snapshot) {
        queue.async {
            self.settings = settings
            self.flashDetector.reset()
            self.flashDetector.minContrast = settings.minFlashContrast
            self.beepDetector.reset()
            self.analyzer.reset()
            self.snapshot = Snapshot()
            self.screenRegion = nil
            self.lastIdleFrame = nil
            self.darkReference = nil
            self.brightestFlashFrame = nil
            self.distanceEstimates = []
            self.lastFrameTime = nil
            self.emit(force: true)
        }
    }

    func ingest(_ frame: LumaFrame) {
        queue.async { self.handle(frame) }
    }

    func ingest(_ chunk: AudioSampleConverter.Chunk) {
        queue.async { self.handle(chunk) }
    }

    // MARK: - Video

    private func handle(_ frame: LumaFrame) {
        if let last = lastFrameTime, frame.time > last {
            let fps = 1 / (frame.time - last)
            snapshot.measuredFrameRate = snapshot.measuredFrameRate == 0 ? fps : 0.95 * snapshot.measuredFrameRate + 0.05 * fps
        }
        lastFrameTime = frame.time
        snapshot.hasIntrinsics = frame.focalLengthPixels != nil

        let luma = regionMean(frame)
        var time = frame.time + settings.cameraTimestampOffsetMs / 1000
        if settings.useExposureMidpoint { time += frame.exposureDuration / 2 }

        let event = flashDetector.add(time: time, luma: luma)
        snapshot.lumaLevel = luma
        snapshot.lumaBaseline = flashDetector.baseline
        snapshot.isInFlash = flashDetector.isInFlash

        switch event {
        case .none:
            if flashDetector.isInFlash {
                if brightestFlashFrame.map({ frame.mean > $0.mean }) ?? true { brightestFlashFrame = frame }
            } else {
                lastIdleFrame = frame
            }
        case .started:
            darkReference = lastIdleFrame
            brightestFlashFrame = frame
        case .completed(let onset, let contrast):
            analyzer.addFlash(onset)
            snapshot.flashCount = analyzer.flashCount
            learnScreen(contrast: contrast)
            refreshSummary()
            emit(force: true)
            return
        }
        emit(force: false)
    }

    /// Mean luminance over the learned screen region, or over the central half of the frame
    /// until a region is known. The screen region gives far better contrast when the screen
    /// is small in the frame.
    private func regionMean(_ frame: LumaFrame) -> Double {
        let rect = screenRegion?.inset
            ?? CellRect(minCol: frame.cols / 4, maxCol: frame.cols * 3 / 4 - 1,
                        minRow: frame.rows / 4, maxRow: frame.rows * 3 / 4 - 1)
        var sum = 0.0
        var n = 0
        for r in max(0, rect.minRow)...min(frame.rows - 1, rect.maxRow) {
            for c in max(0, rect.minCol)...min(frame.cols - 1, rect.maxCol) {
                sum += Double(frame.cells[r * frame.cols + c])
                n += 1
            }
        }
        return n > 0 ? sum / Double(n) : frame.mean
    }

    private func learnScreen(contrast: Double) {
        defer { darkReference = nil; brightestFlashFrame = nil }
        guard let dark = darkReference, let bright = brightestFlashFrame,
              dark.cells.count == bright.cells.count else { return }
        // Cells that brightened by at least half the detected contrast belong to the screen.
        let threshold = Float(max(settings.minFlashContrast * 0.5, 0.5 * contrast))
        guard let measurement = ScreenSizeRanger.brightRegion(current: bright.cells, dark: dark.cells,
                                                              cols: bright.cols, rows: bright.rows,
                                                              threshold: threshold) else { return }
        if measurement.rect != screenRegion {
            screenRegion = measurement.rect
            flashDetector.rebaseline()
        }
        snapshot.screenRect = measurement.rect.normalized(cols: bright.cols, rows: bright.rows)

        guard ScreenSizeRanger.isFullyVisible(measurement.rect, cols: bright.cols, rows: bright.rows),
              let focal = bright.focalLengthPixels,
              let d = ScreenSizeRanger.distance(measurement: measurement, cols: bright.cols, rows: bright.rows,
                                                width: bright.width, height: bright.height,
                                                focalLengthPixels: focal,
                                                screenDiagonalMeters: settings.screenDiagonalMeters),
              d.isFinite, d > 0.2, d < 60 else { return }
        distanceEstimates.append(d)
        snapshot.cameraDistance = Statistics.median(distanceEstimates)
        snapshot.cameraDistanceSamples = distanceEstimates.count
    }

    // MARK: - Audio

    private func handle(_ chunk: AudioSampleConverter.Chunk) {
        let onsets = beepDetector.process(chunk.samples, sampleRate: chunk.sampleRate, startTime: chunk.startTime)
        snapshot.audioLevel = beepDetector.level
        snapshot.audioNoiseFloor = beepDetector.noiseFloor
        guard !onsets.isEmpty else { emit(force: false); return }
        for t in onsets { analyzer.addBeep(t) }
        snapshot.beepCount = analyzer.beepCount
        refreshSummary()
        emit(force: true)
    }

    // MARK: - Publishing

    private func refreshSummary() {
        snapshot.summary = analyzer.summary
        snapshot.recentOffsets = Array(analyzer.offsets.suffix(12))
        snapshot.pairs = analyzer.pairs
        snapshot.drift = DriftAnalyzer.estimate(pairs: analyzer.pairs)
        snapshot.slips = DriftAnalyzer.slips(pairs: analyzer.pairs,
                                             frameDurationMs: settings.frameRate.frameDuration * 1000,
                                             slopeMsPerMinute: snapshot.drift?.slopeMsPerMinute)
    }

    private func emit(force: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastEmit > 0.1 else { return }
        lastEmit = now
        onUpdate?(snapshot)
    }
}
