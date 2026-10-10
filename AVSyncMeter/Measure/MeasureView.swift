import SwiftUI

struct MeasureView: View {
    @State private var model = MeasurementModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    cameraArea
                    phaseBanner
                    if model.snapshot.summary.count > 0 {
                        resultCard
                    }
                    if model.settings.driftMode || model.snapshot.drift != nil {
                        driftCard
                    }
                    distanceCard
                    liveCard
                    controlButton
                    tips
                }
                .padding()
            }
            .navigationTitle("AV Sync Meter")
        }
        .onAppear { model.refreshSettings() }
        .onDisappear { model.stop() }
    }

    // MARK: - Camera / status

    private var cameraArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black)
            switch model.phase {
            case .settling, .measuring:
                CameraPreview(session: model.captureSession,
                              screenRect: model.snapshot.screenRect,
                              highlight: model.snapshot.isInFlash)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            case .ranging:
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Measuring distance with LiDAR.\nAim the camera at the centre of the screen.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    if let d = model.lidarDistance {
                        Text(String(format: "%.2f m", d)).font(.title.monospacedDigit()).foregroundStyle(.white)
                    }
                }
            case .requestingPermission, .startingCamera:
                ProgressView().tint(.white)
            case .idle, .finished, .failed:
                VStack(spacing: 10) {
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.white)
                    Text("Play the test pattern on the screen under test, aim the back camera at it so the whole screen is in view, and tap Start.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .font(.callout)
                        .padding(.horizontal)
                }
            }
        }
        .frame(height: 300)
    }

    private var phaseBanner: some View {
        HStack {
            Image(systemName: phaseSymbol)
            Text(phaseText)
            Spacer()
            if model.isRunning { ProgressView() }
        }
        .font(.subheadline)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var phaseSymbol: String {
        switch model.phase {
        case .idle: return "circle"
        case .requestingPermission: return "lock.shield"
        case .ranging: return "ruler"
        case .startingCamera: return "camera"
        case .settling: return "sun.max"
        case .measuring: return "waveform"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var phaseText: String {
        switch model.phase {
        case .idle: return "Ready"
        case .requestingPermission: return "Requesting camera and microphone access"
        case .ranging: return "Ranging with LiDAR (\(model.lidarSampleCount) samples)"
        case .startingCamera: return "Starting camera"
        case .settling: return "Settling and locking exposure. Keep still."
        case .measuring:
            let n = model.snapshot.summary.count
            if model.settings.driftMode {
                return "Drift run: \(clock(model.elapsedRunSeconds)) of \(model.settings.driftDurationMinutes) min, \(n) events"
            }
            return "Measuring: \(n) of \(model.settings.targetEventCount) events"
        case .finished: return "Done"
        case .failed(let message): return message
        }
    }

    // MARK: - Results

    private var resultCard: some View {
        let summary = model.snapshot.summary
        return VStack(alignment: .leading, spacing: 8) {
            if let listener = model.offsetAtListener {
                let listenerMs = listener * 1000
                Text(SyncStandards.describe(offsetMs: listenerMs))
                    .font(.title2.bold())
                Text("as seen and heard at the phone  (\(framesText(listener)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let source = model.offsetAtSource, let distance = model.distance, let travel = model.propagationDelay {
                    Divider()
                    Text(SyncStandards.describe(offsetMs: source * 1000))
                        .font(.title3.bold())
                    Text(String(format: "at the screen (%@): %.1f ms of sound travel over %.2f m (%@) removed",
                                framesText(source), travel * 1000, distance.meters, distance.source.rawValue))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    verdictView(offsetMs: source * 1000)
                } else {
                    verdictView(offsetMs: listenerMs)
                    Text("Add a distance (LiDAR, screen size in Settings, or a manual value) to also get the offset at the screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    statistic("Events", "\(summary.count)")
                    statistic("Spread (MAD)", milliseconds(summary.mad))
                    statistic("Min", milliseconds(summary.min, signed: true))
                    statistic("Max", milliseconds(summary.max, signed: true))
                }
                if !model.snapshot.recentOffsets.isEmpty {
                    Text("Recent (ms): " + model.snapshot.recentOffsets.map { String(format: "%+.0f", $0 * 1000) }.joined(separator: "  "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !model.isRunning {
                    ShareLink(item: ResultsExport(csv: model.resultsCSV()),
                              preview: SharePreview("AV sync results (CSV)")) {
                        Label("Export CSV of all \(summary.count) events", systemImage: "square.and.arrow.up")
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func verdictView(offsetMs: Double) -> some View {
        let verdict = SyncStandards.verdict(offsetMs: offsetMs)
        let color: Color
        switch verdict.severity {
        case .good: color = .green
        case .noticeable: color = .orange
        case .bad: color = .red
        }
        return VStack(alignment: .leading, spacing: 2) {
            Label(verdict.title, systemImage: "circle.fill")
                .foregroundStyle(color)
                .font(.subheadline.bold())
            Text(verdict.detail).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var driftCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drift").font(.headline)
            if let drift = model.snapshot.drift {
                HStack {
                    statistic("Slope", String(format: "%+.2f ms/min", drift.slopeMsPerMinute))
                    statistic("Per hour", String(format: "%+.1f frames", drift.framesPerHour(fps: model.frameRate.fps)))
                    statistic("Over run", String(format: "%+.1f ms", drift.totalDriftMs))
                    statistic("Ratio", String(format: "%+.0f ppm", drift.partsPerMillion))
                }
                Text(DriftAnalyzer.interpretation(of: drift))
                    .font(.footnote)
                Text(String(format: "%d events over %@, residual spread %.2f ms (MAD).",
                            drift.count, clock(drift.spanSeconds), drift.residualMadMs))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: "Needs at least %d events over %.0f s. Keep the pattern running.",
                            DriftAnalyzer.minimumCount, DriftAnalyzer.minimumSpanSeconds))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !model.snapshot.slips.isEmpty {
                Divider()
                Text("Steps in the offset (frame slips)").font(.subheadline.bold())
                ForEach(model.snapshot.slips) { slip in
                    Text(String(format: "at %@: %+.1f ms (%+.2f frames)",
                                clock(slip.time), slip.deltaMs, slip.deltaMs / 1000 * model.frameRate.fps))
                        .font(.caption.monospaced())
                }
            } else if model.snapshot.drift != nil {
                Text("No frame slips detected.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var distanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Distance to screen").font(.headline)
            if let d = model.distance {
                HStack {
                    Text(String(format: "%.2f m", d.meters)).font(.title3.monospacedDigit())
                    Text("(\(d.source.rawValue))").foregroundStyle(.secondary)
                    Spacer()
                    if let travel = model.propagationDelay {
                        Text(String(format: "sound: %.1f ms", travel * 1000)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Not yet known").foregroundStyle(.secondary)
            }
            Group {
                if model.settings.useManualDistance {
                    Text("Manual distance from Settings.")
                } else {
                    Text(model.lidarSupported
                         ? "LiDAR is used first (up to about 5 m)."
                         : "This device has no LiDAR.")
                    if let camera = model.snapshot.cameraDistance {
                        Text(String(format: "Camera estimate from a %.0f\" screen: %.2f m (%d flashes).",
                                    model.settings.screenDiagonalInches, camera, model.snapshot.cameraDistanceSamples))
                    } else if !model.snapshot.hasIntrinsics && model.phase == .measuring {
                        Text("Camera intrinsics unavailable: screen-size estimate disabled.")
                    } else {
                        Text(String(format: "Screen-size estimate uses the %.0f\" diagonal from Settings once the whole screen is in view.",
                                    model.settings.screenDiagonalInches))
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveCard: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 6) {
            Text("Live").font(.headline)
            HStack {
                statistic("Flashes", "\(s.flashCount)")
                statistic("Beeps", "\(s.beepCount)")
                statistic("Camera", s.measuredFrameRate > 0 ? String(format: "%.0f fps", s.measuredFrameRate) : "-")
                statistic("Audio", decibels(s.audioLevel))
            }
            HStack {
                statistic("Luma", String(format: "%.0f", s.lumaLevel))
                statistic("Baseline", s.lumaBaseline.map { String(format: "%.0f", $0) } ?? "-")
                statistic("Noise floor", decibels(s.audioNoiseFloor))
                statistic("Format", model.formatSummary.isEmpty ? "-" : model.formatSummary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var controlButton: some View {
        Button {
            if model.isRunning { model.stop() } else { model.start() }
        } label: {
            Text(model.isRunning ? "Stop" : (model.phase == .finished ? "Measure again" : "Start"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRunning ? .red : .accentColor)
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tips").font(.headline)
            Text("• Hold the phone where the audience sits, or rest it on something.\n• Keep the whole screen in view with some dark border around it.\n• Dim room lights if the flash is not detected.\n• Keep the room quiet; the beep must be clearly louder than the background.\n• Positive numbers mean the audio arrives late (lags the picture).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting helpers

    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func framesText(_ seconds: Double) -> String {
        String(format: "%+.2f frames at %@ fps", model.frames(fromSeconds: seconds), model.frameRate.label)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func milliseconds(_ seconds: Double?, signed: Bool = false) -> String {
        guard let seconds else { return "-" }
        return String(format: signed ? "%+.1f ms" : "%.1f ms", seconds * 1000)
    }

    private func decibels(_ linear: Double) -> String {
        guard linear > 1e-6 else { return "-inf dB" }
        return String(format: "%.0f dB", 20 * log10(linear))
    }
}
