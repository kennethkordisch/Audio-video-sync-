import Charts
import SwiftUI

/// Offset versus time for one run.
struct OffsetChart: View {
    let points: [RunPoint]
    let fps: Double
    let showBands: Bool

    var body: some View {
        Chart {
            ForEach(points) { p in
                PointMark(x: .value("Time (s)", p.time), y: .value("Offset (ms)", p.offsetMs))
                    .foregroundStyle(by: .value("Channel", showBands ? (p.band == 0 ? "Left" : "Right") : "Offset"))
                    .symbolSize(20)
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.5))
            RuleMark(y: .value("Lead limit", -SyncStandards.ebuLeadLimitMs))
                .foregroundStyle(.orange.opacity(0.5))
                .lineStyle(StrokeStyle(dash: [4, 4]))
            RuleMark(y: .value("Lag limit", SyncStandards.ebuLagLimitMs))
                .foregroundStyle(.orange.opacity(0.5))
                .lineStyle(StrokeStyle(dash: [4, 4]))
        }
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("ms (+ = audio late)")
        .chartLegend(showBands ? .visible : .hidden)
    }
}
