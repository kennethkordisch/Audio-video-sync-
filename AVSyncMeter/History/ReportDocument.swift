import CoreGraphics
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// One-page PDF report for a saved run, rendered from SwiftUI with ImageRenderer.
struct ReportDocument: Transferable {
    let run: RunRecord
    let comparison: RunRecord?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { document in
            let url = try await document.render()
            return SentTransferredFile(url)
        }
        .suggestedFileName { "avsync_\($0.run.label.isEmpty ? "run" : $0.run.label.replacingOccurrences(of: " ", with: "_")).pdf" }
    }

    @MainActor
    func render() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("avsync_report_\(run.id.uuidString).pdf")
        let renderer = ImageRenderer(content: ReportView(run: run, comparison: comparison).frame(width: 612))
        renderer.scale = 2
        var failed = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { failed = true; return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
        }
        if failed { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

struct ReportView: View {
    let run: RunRecord
    let comparison: RunRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                Text("AV sync measurement").font(.title.bold())
                Text(run.label.isEmpty ? "Untitled run" : run.label).font(.title3)
                Text(run.date, format: .dateTime).foregroundStyle(.secondary)
                Divider()
            }
            Text(SyncStandards.describe(offsetMs: run.headlineOffsetMs)).font(.title2.bold())
            Text(String(format: "%+.1f ms = %+.2f frames at %@ fps, %@", run.headlineOffsetMs, run.headlineOffsetFrames,
                        run.frameRateLabel, run.offsetAtScreenMs != nil ? "at the screen (sound travel removed)" : "at the phone"))
            let verdict = SyncStandards.verdict(offsetMs: run.headlineOffsetMs)
            Text("\(verdict.title). \(verdict.detail)").font(.callout)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow { Text("At the phone"); Text(String(format: "%+.1f ms", run.offsetAtPhoneMs)) }
                if let s = run.offsetAtScreenMs { GridRow { Text("At the screen"); Text(String(format: "%+.1f ms", s)) } }
                if let d = run.distanceMeters { GridRow { Text("Distance"); Text(String(format: "%.2f m (%@), %.1f ms of travel", d, run.distanceSource ?? "", d / 343 * 1000)) } }
                GridRow { Text("Events / spread"); Text(String(format: "%d events, MAD %.1f ms", run.eventCount, run.madMs)) }
                if let drift = run.driftMsPerMinute { GridRow { Text("Drift"); Text(String(format: "%+.2f ms/min (%+.1f frames/hour), %d frame slips", drift, drift * 60 / 1000 * run.fps, run.slipCount)) } }
                if let l = run.leftOffsetMs, let r = run.rightOffsetMs { GridRow { Text("Left / right"); Text(String(format: "%+.1f / %+.1f ms", l, r)) } }
                GridRow { Text("Mode / camera offset"); Text(String(format: "%@, %+.1f ms", run.mode, run.cameraOffsetMs)) }
            }
            .font(.callout.monospacedDigit())

            OffsetChart(points: run.points, fps: run.fps, showBands: run.leftOffsetMs != nil)
                .frame(height: 220)

            if let other = comparison {
                Divider()
                let delta = run.headlineOffsetMs - other.headlineOffsetMs
                Text(String(format: "Compared with \"%@\" (%@): %+.1f ms, %+.2f frames.",
                            other.label.isEmpty ? "other run" : other.label,
                            other.date.formatted(date: .abbreviated, time: .shortened), delta, delta / 1000 * run.fps))
                    .font(.callout)
            }

            Divider()
            Text("Positive = audio later than video. Measured with AVSyncMeter: camera flash detection at up to 240 fps and 1 kHz beep onset detection on one capture clock; median of all events. References: EBU R37 (-40/+60 ms), ITU-R BT.1359 (-45/+125 ms detectability).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .background(Color.white)
        .foregroundStyle(.black)
    }
}
