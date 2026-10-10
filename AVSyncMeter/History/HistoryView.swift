import SwiftUI

/// Saved runs: list, detail with chart, A/B comparison, CSV and PDF export.
struct HistoryView: View {
    @State private var store = RunStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.runs.isEmpty {
                    ContentUnavailableView("No saved runs",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("After a measurement, tap \"Save run\" on the Measure tab. Label runs by chain or by seat to compare them here."))
                } else {
                    List {
                        ForEach(store.runs) { run in
                            NavigationLink(value: run.id) {
                                RunRow(run: run)
                            }
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                    .navigationDestination(for: UUID.self) { id in
                        if let run = store.runs.first(where: { $0.id == id }) {
                            RunDetailView(run: run)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !store.runs.isEmpty {
                    EditButton()
                }
            }
        }
    }
}

struct RunRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(run.label.isEmpty ? "Untitled run" : run.label).font(.headline)
                Spacer()
                Text(String(format: "%+.1f ms", run.headlineOffsetMs)).font(.headline.monospacedDigit())
            }
            HStack {
                Text(run.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("•")
                Text("\(run.frameRateLabel) fps")
                Text("•")
                Text("\(run.eventCount) events")
                if run.driftMsPerMinute != nil { Text("•"); Text("drift") }
                Spacer()
                Text(String(format: "%+.2f fr", run.headlineOffsetFrames))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct RunDetailView: View {
    @State private var store = RunStore.shared
    @State private var run: RunRecord
    @State private var compareID: UUID?
    @State private var editingLabel = false
    @State private var newLabel = ""

    init(run: RunRecord) {
        _run = State(initialValue: run)
    }

    private var comparison: RunRecord? {
        guard let compareID else { return nil }
        return store.runs.first { $0.id == compareID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard
                OffsetChart(points: run.points, fps: run.fps, showBands: run.leftOffsetMs != nil)
                    .frame(height: 220)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                compareCard
                exportCard
            }
            .padding()
        }
        .navigationTitle(run.label.isEmpty ? "Run" : run.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Rename") {
                newLabel = run.label
                editingLabel = true
            }
        }
        .alert("Label", isPresented: $editingLabel) {
            TextField("Chain or seat", text: $newLabel)
            Button("Save") {
                run.label = newLabel
                store.update(run)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SyncStandards.describe(offsetMs: run.headlineOffsetMs)).font(.title3.bold())
            Text(String(format: "%+.2f frames at %@ fps  •  %@", run.headlineOffsetFrames, run.frameRateLabel,
                        run.offsetAtScreenMs != nil ? "at the screen" : "at the phone"))
                .font(.subheadline).foregroundStyle(.secondary)
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Date").foregroundStyle(.secondary); Text(run.date, format: .dateTime) }
                GridRow { Text("Mode").foregroundStyle(.secondary); Text(run.mode) }
                GridRow { Text("At phone").foregroundStyle(.secondary); Text(String(format: "%+.1f ms", run.offsetAtPhoneMs)) }
                if let screen = run.offsetAtScreenMs {
                    GridRow { Text("At screen").foregroundStyle(.secondary); Text(String(format: "%+.1f ms", screen)) }
                }
                GridRow { Text("Spread (MAD)").foregroundStyle(.secondary); Text(String(format: "%.1f ms", run.madMs)) }
                GridRow { Text("Events").foregroundStyle(.secondary); Text("\(run.eventCount)") }
                if let d = run.distanceMeters {
                    GridRow { Text("Distance").foregroundStyle(.secondary); Text(String(format: "%.2f m (%@)", d, run.distanceSource ?? "")) }
                }
                if let drift = run.driftMsPerMinute {
                    GridRow { Text("Drift").foregroundStyle(.secondary); Text(String(format: "%+.2f ms/min, %d slips", drift, run.slipCount)) }
                }
                if let l = run.leftOffsetMs, let r = run.rightOffsetMs {
                    GridRow { Text("Left / Right").foregroundStyle(.secondary); Text(String(format: "%+.1f / %+.1f ms (L−R %+.1f)", l, r, l - r)) }
                }
                GridRow { Text("Camera offset").foregroundStyle(.secondary); Text(String(format: "%+.1f ms", run.cameraOffsetMs)) }
            }
            .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare").font(.headline)
            Picker("With", selection: $compareID) {
                Text("None").tag(UUID?.none)
                ForEach(store.runs.filter { $0.id != run.id }) { other in
                    Text(other.label.isEmpty ? other.date.formatted(date: .abbreviated, time: .shortened) : other.label)
                        .tag(UUID?.some(other.id))
                }
            }
            if let other = comparison {
                let delta = run.headlineOffsetMs - other.headlineOffsetMs
                Text(String(format: "This run minus \"%@\": %+.1f ms (%+.2f frames at %@ fps)",
                            other.label.isEmpty ? "other" : other.label, delta, delta / 1000 * run.fps, run.frameRateLabel))
                    .font(.callout.monospacedDigit())
                Text(abs(delta) < max(run.madMs, other.madMs) * 2
                     ? "Within the measurement spread: no meaningful difference."
                     : "A real difference between the two chains or seats.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let d1 = run.distanceMeters, let d2 = other.distanceMeters, abs(d1 - d2) > 0.3 {
                    Text(String(format: "Seats differ by %.1f m, i.e. %.1f ms of sound travel.", abs(d1 - d2), abs(d1 - d2) / 343 * 1000))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var exportCard: some View {
        HStack {
            ShareLink(item: ResultsExport(csv: run.csv), preview: SharePreview("\(run.label) (CSV)")) {
                Label("CSV", systemImage: "tablecells")
            }
            .buttonStyle(.bordered)
            ShareLink(item: ReportDocument(run: run, comparison: comparison),
                      preview: SharePreview("\(run.label) report (PDF)")) {
                Label("PDF report", systemImage: "doc.richtext")
            }
            .buttonStyle(.bordered)
        }
    }
}
