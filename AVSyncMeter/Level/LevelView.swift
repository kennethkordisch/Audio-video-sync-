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

    // MARK: - Pink-noise sequence

    private var sequenceCard: some View {
        let s = model.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            Text("Pink the speakers").font(.headline)
            HStack {
                Picker("Layout", selection: $layoutRaw) {
                    ForEach(SpeakerLayout.allCases) { l in Text(l.rawValue).tag(l.rawValue) }
                }
                .pickerStyle(.segmented)
            }
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
            }
            HStack {
                if s.sequenceActive {
                    Button(role: .destructive) { model.stopSequence() } label: { Label("Stop sequence", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent)
                    Text(s.segmentInProgress
                         ? String(format: "Measuring %@: %.1f dB", nextChannelName(count: s.readings.count), s.currentSegmentLevel ?? s.level)
                         : "Waiting for \(nextChannelName(count: s.readings.count))…")
                        .font(.callout.monospacedDigit())
                } else {
                    Button { model.startSequence() } label: { Label("Start sequence", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Text("Then play the pink-noise file (channels in the order below).").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !s.readings.isEmpty {
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Channel").foregroundStyle(.secondary)
                        Text("Leq C").foregroundStyle(.secondary)
                        Text("Target").foregroundStyle(.secondary)
                        Text("Trim").foregroundStyle(.secondary)
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
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                Text("Trim is what to add on each channel's output level to reach the target. Within ±0.5 dB is matched.")
                    .font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: ResultsExport(csv: model.readingsCSV(layout: layout, target: target, lfeOffset: lfeOffset, offset: offset, weighting: weighting)),
                          preview: SharePreview("Speaker levels (CSV)")) {
                    Label("Export CSV", systemImage: "tablecells")
                }
                .font(.subheadline)
            }
            Text("Channel order: \(layout.channels.joined(separator: ", ")). Each burst is detected when the C-weighted level rises above target − 20 dB; the Leq skips the first half second. Stand or sit at the listening position with the phone at ear height.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
        Text("Reference levels: 85 dB C-slow per channel at −20 dBFS RMS pink noise is the film/cinema and large mix-room standard, 79 dB for small rooms and broadcast, 82 or 76 in between. LFE is usually set +10 dB in-band in cinema; set LFE +0 if you calibrate the sub by ear or the bass management handles it. Make the pink file in the Mac app (Pink noise tab) or with tools/make_pink_noise.sh.")
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
