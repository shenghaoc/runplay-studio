import SwiftUI
import RunPlayCore
import Charts


/// Chart showing pace comparison over distance.
struct ComparisonChartView: View {
    let metrics: [ComparisonMetricPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pace Over Distance")
                .font(.headline)

            Chart {
                ForEach(metrics) { point in
                    if let primaryPace = point.primaryPace, primaryPace.isFinite {
                        LineMark(
                            x: .value("Distance (km)", point.distanceKm),
                            y: .value("Pace", primaryPace)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)
                    }

                    if let comparisonPace = point.comparisonPace, comparisonPace.isFinite {
                        LineMark(
                            x: .value("Distance (km)", point.distanceKm),
                            y: .value("Pace", comparisonPace)
                        )
                        .foregroundStyle(.red)
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let km = value.as(Double.self) {
                            Text("\(Int(km)) km")
                        }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let pace = value.as(Double.self) {
                            let mins = Int(pace) / 60
                            let secs = Int(pace) % 60
                            Text("\(mins):\(String(format: "%02d", secs))")
                        }
                    }
                    AxisGridLine()
                }
            }

            // Legend
            HStack(spacing: 16) {
                Label("Primary", systemImage: "circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Label("Comparison", systemImage: "circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Split Comparison Table

struct SplitComparisonTableView: View {
    let splits: [SplitComparison]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split Comparison")
                .font(.headline)

            Table(splits) {
                TableColumn("Split") { split in
                    Text("\(split.splitIndex)")
                        .monospacedDigit()
                }
                .width(40)

                TableColumn("Primary") { split in
                    if let s = split.primarySplit {
                        Text(s.formattedPace)
                            .monospacedDigit()
                    } else {
                        Text("—")
                    }
                }
                .width(70)

                TableColumn("Comparison") { split in
                    if let s = split.comparisonSplit {
                        Text(s.formattedPace)
                            .monospacedDigit()
                    } else {
                        Text("—")
                    }
                }
                .width(80)

                TableColumn("Delta") { split in
                    Text(split.formattedPaceDelta)
                        .monospacedDigit()
                        .foregroundStyle(deltaColor(split.paceDeltaSecondsPerKm))
                }
                .width(70)

                TableColumn("Winner") { split in
                    Text(split.winner.label)
                        .font(.caption)
                }
                .width(80)
            }
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        guard let d = delta else { return .secondary }
        if abs(d) < 5 { return .secondary }
        return d < 0 ? .green : .red
    }
}
