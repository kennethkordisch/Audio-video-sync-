import SwiftUI

struct LevelView: View {
    @AppStorage(AppSettings.Key.splOffsetDB) private var offset = 120.0
    @AppStorage(AppSettings.Key.splTargetDB) private var target = 85.0
    @AppStorage(AppSettings.Key.lfeOffsetDB) private var lfeOffset = 10.0
    @AppStorage(AppSettings.Key.splLayout) private var layoutRaw = SpeakerLayout.fiveOne.rawValue
    @AppStorage(AppSettings.Key.splWeighting) private var weightingRaw = Weighting.c.rawValue
    @AppStorage(AppSettings.Key.splTimeWeighting) private var timeRaw = TimeWeighting.slow.rawValue
    @State private var model = LevelMeterModel()
    @State private var referenceReading = 85.0
    @State private var captureSeconds = 5.0

    private var layout: SpeakerLayout { SpeakerLayout(rawValue: layoutRaw) ?? .fiveOne }
    private var weighting: Weighting { Weighting(rawValue: weightingRaw) ?? .c }
    private var timeWeighting: TimeWeighting { TimeWeighting(rawValue: timeRaw) ?? .slow }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    meterCard
                    sequenceCard
                    calibrationCard
                    notes
                }
                .padding()
            }
            .navigationTitle("Speaker Levels")
        }
        .onAppear {
            pushSettings()
            model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: offset) { _, _ in pushSettings() }
        .onChange(of: target) { _, _ in pushSettings() }
        .onChange(of: layoutRaw) { _, _ in pushSettings() }
        .onChange(of: weightingRaw) { _, _ in pushSettings() }
        .onChange(of: timeRaw) { _, _ in pushSettings() }
    }

    private func pushSettings() {
        model.apply(offset: offset, weighting: weighting, timeWeighting: timeWeighting, layout: layout, target: target)
    }

    // MARK: - Meter

    private var meterCard: some View {
        let s = model.snapshot
        return VStack(spacing: 10) {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
            Text(String(format: "%.1f", s.level))
                .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
            Text("dB SPL (\(weighting.rawValue), \(timeWeighting.rawValue))")
                .foregroundStyle(.secondary)
            levelBar(value: s.level)
            HStack {
                Picker("Weighting", selection: $weightingRaw) {
                    ForEach(Weighting.allCases) { w in Text(w.rawValue).tag(w.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Time", selection: $timeRaw) {
                    ForEach(TimeWeighting.allCases) { t in Text(t.rawValue).tag(t.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            HStack {
                stat("Leq", String(format: "%.1f dB (%@)", s.leq, clock(s.leqSeconds)))
                stat("Peak", String(format: "%.1f dB", s.peak))
                stat("A / C / Z", String(format: "%.0f / %.0f / %.0f", s.levelA, s.levelC, s.levelZ))
                Button("Reset") { model.resetLeq() }.buttonStyle(.bordered).font(.footnote)
            }
            Text(String(format: "Target %.0f dB. Difference: %+.1f dB", target, target - s.level))
                .font(.callout.monospacedDigit())
                .foregroundStyle(abs(target - s.level) < 0.5 ? .green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func levelBar(value: Double) -> some View {
        GeometryReader { geo in
            let lo = 40.0, hi = 110.0
            let frac = min(1, max(0, (value - lo) / (hi - lo)))
            let targetFrac = min(1, max(0, (target - lo) / (hi - lo)))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 4)
                    .fill(abs(value - target) < 0.5 ? Color.green : (value > target ? Color.orange : Color.accentColor))
                    .frame(width: geo.size.width * frac)
                Rectangle().fill(Color.primary).frame(width: 2).offset(x: geo.size.width * targetFrac)
            }
        }
        .frame(height: 14)
    }

    // MARK: - Per-speaker readings

    private var sequenceCard: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pink the speakers").font(.headline)
            Picker("Layout", selection: $layoutRaw) {
                ForEach(SpeakerLayout.allCases) { l in Text(l.rawValue).tag(l.rawValue) }
            }
            .pickerStyle(.segmented)
            HStack {
                Picker("Target", selection: $target) {
                    Text("85 dB").tag(85.0)
                    Text("82 dB").tag(82.0)
                    Text("79 dB").tag(79.0)
                    Text("76 dB").tag(76.0)
                    Text("73 dB").tag(73.0)
                }
                Picker("LFE", selection: $lfeOffset) {
                    Text("LFE +10").tag(10.0)
                    Text("LFE +4").tag(4.0)
                    Text("LFE +0").tag(0.0)
                }
                Picker("Read for", selection: $captureSeconds) {
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
            }

            Text("Play pink noise on one speaker, then tap it:").font(.subheadline)
            channelButtons(snapshot: s)

            if let name = s.capturingChannel {
                HStack {
                    ProgressView(value: s.captureProgress)
                    Text(String(format: "%@  %.1f dB", name, s.levelC)).font(.callout.monospacedDigit())
                    Button("Cancel") { model.cancelCapture() }.font(.footnote)
                }
            }

            if !s.readings.isEmpty {
                Divider()
                readingsTable(snapshot: s)
            }

            DisclosureGroup("Auto mode: follow bursts in file order") {
                HStack {
                    if s.sequenceActive {
                        Button(role: .destructive) { model.stopSequence() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.bordered)
                        Text(s.segmentInProgress
                             ? String(format: "Measuring %@: %.1f dB", nextChannelName(count: s.readings.count), s.currentSegmentLevel ?? s.level)
                             : "Waiting for \(nextChannelName(count: s.readings.count))…")
                            .font(.callout.monospacedDigit())
                    } else {
                        Button { model.startSequence() } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.bordered)
                        Text("For files that play \(layout.channels.joined(separator: ", ")) in that order with gaps between channels. A burst is detected above target − 20 dB.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func channelButtons(snapshot s: LevelSnapshot) -> some View {
        let names = layout.channels
        let columns = [GridItem(.adaptive(minimum: 64), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(names, id: \.self) { name in
                Button {
                    model.capture(channel: name, seconds: captureSeconds)
                } label: {
                    VStack(spacing: 2) {
                        Text(name).font(.headline)
                        if let r = s.readings.first(where: { $0.name == name }) {
                            Text(String(format: "%.1f", r.leq)).font(.caption.monospacedDigit())
                        } else {
                            Text("—").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(s.capturingChannel == name ? .orange : (s.readings.contains { $0.name == name } ? .green : .accentColor))
                .disabled(s.capturingChannel != nil)
            }
        }
    }

    private func readingsTable(snapshot s: LevelSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Speaker").foregroundStyle(.secondary)
                    Text("Leq C").foregroundStyle(.secondary)
                    Text("Target").foregroundStyle(.secondary)
                    Text("Trim").foregroundStyle(.secondary)
                    Text("")
                }
                ForEach(s.readings) { r in
                    let t = model.target(for: r.name, base: target, lfeOffset: lfeOffset)
                    let trim = t - r.leq
                    GridRow {
                        Text(r.name).bold()
                        Text(String(format: "%.1f", r.leq))
                        Text(String(format: "%.1f", t))
                        Text(String(format: "%+.1f dB", trim))
                            .foregroundStyle(abs(trim) < 0.5 ? .green : (abs(trim) < 1.5 ? .orange : .red))
                        Button { model.removeReading(named: r.name) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout.monospacedDigit())
            if s.readings.count >= 2 {
                let levels = s.readings.filter { $0.name != "LFE" }.map(\.leq)
                if let hi = levels.max(), let lo = levels.min() {
                    Text(String(format: "Spread between speakers (excluding LFE): %.1f dB", hi - lo))
                        .font(.footnote).foregroundStyle(hi - lo < 1 ? .green : .secondary)
                }
            }
            Text("Trim = target − measured: what to add to that speaker's output level. Within ±0.5 dB is matched.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                ShareLink(item: ResultsExport(csv: model.readingsCSV(layout: layout, target: target, lfeOffset: lfeOffset, offset: offset, weighting: weighting)),
                          preview: SharePreview("Speaker levels (CSV)")) {
                    Label("Export CSV", systemImage: "tablecells")
                }
                Spacer()
                Button("Clear", role: .destructive) { model.clearReadings() }
            }
            .font(.subheadline)
        }
    }

    private func nextChannelName(count: Int) -> String {
        let names = layout.channels
        return count < names.count ? names[count] : "extra segment"
    }

    // MARK: - Calibration

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibration offset").font(.headline)
            HStack {
                Text("Offset").foregroundStyle(.secondary)
                TextField("dB", value: $offset, format: .number.precision(.fractionLength(1)))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("dB").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "raw %.1f dBFS", model.snapshot.dbfs)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text("Reference meter reads").foregroundStyle(.secondary)
                TextField("dB", value: $referenceReading, format: .number.precision(.fractionLength(1)))
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Button("Match") {
                    offset = referenceReading - model.snapshot.dbfs
                }
                .buttonStyle(.bordered)
            }
            Text("The iPhone microphone is not a calibrated SPL meter. Play steady pink noise, read a real SPL meter (C, slow) at the same spot, type it here and tap Match. Relative levels between speakers are accurate to a fraction of a dB without calibration; absolute level depends on this offset.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var notes: some View {
        Text("Reference levels: 85 dB C-slow per channel at −20 dBFS RMS pink noise is the film/cinema and large mix-room standard, 79 dB for small rooms and broadcast, 82 or 76 in between. LFE is usually set +10 dB in-band in cinema; choose LFE +0 if the bass management or your spec handles it. Use any pink-noise file or the test tones in your AVR or console; readings are taken from whatever is playing when you tap a speaker.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.footnote.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
