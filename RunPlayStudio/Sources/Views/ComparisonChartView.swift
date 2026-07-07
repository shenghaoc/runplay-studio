import SwiftUI
import RunPlayCore
import Charts


/// Chart showing pace comparison over distance.
struct ComparisonChartView: View {
    let metrics: [ComparisonMetricPoint]
    let primaryName: String
    let comparisonName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                Text("Pace Over Distance")
                    .font(.headline)
                Text("(lower is faster)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if metrics.isEmpty {
                ComparisonChartEmptyView()
            } else {
                Chart {
                    ForEach(metrics) { point in
                        if let primaryPace = point.primaryPace, primaryPace.isFinite {
                            LineMark(
                                x: .value("Distance (km)", point.distanceKm),
                                y: .value("min/km", primaryPace)
                            )
                            .foregroundStyle(by: .value("Run", primaryName))
                            .interpolationMethod(.catmullRom)
                        }

                        if let comparisonPace = point.comparisonPace, comparisonPace.isFinite {
                            LineMark(
                                x: .value("Distance (km)", point.distanceKm),
                                y: .value("min/km", comparisonPace)
                            )
                            .foregroundStyle(by: .value("Run", comparisonName))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                }
                .chartForegroundStyleScale([
                    primaryName: .blue,
                    comparisonName: .red
                ])
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
                .chartLegend(position: .bottom) {
                    HStack(spacing: 16) {
                        Label(truncatedName(primaryName), systemImage: "circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Label(truncatedName(comparisonName), systemImage: "circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func truncatedName(_ name: String) -> String {
        if name.count > 20 {
            return String(name.prefix(18)) + "…"
        }
        return name
    }
}

// MARK: - Chart Empty State

struct ComparisonChartEmptyView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No pace data to chart")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Both runs need GPS route points with timing data to build a pace comparison.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Split Comparison Table

struct SplitComparisonTableView: View {
    let splits: [SplitComparison]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split Comparison")
                .font(.headline)

            if splits.isEmpty {
                Text("No splits to compare")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Table(splits) {
                    TableColumn("km") { split in
                        Text("\(split.splitIndex)")
                            .monospacedDigit()
                    }
                    .width(35)

                    TableColumn("Primary (min/km)") { split in
                        if let s = split.primarySplit {
                            Text(s.formattedPace)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(90)

                    TableColumn("Comparison (min/km)") { split in
                        if let s = split.comparisonSplit {
                            Text(s.formattedPace)
                                .monospacedDigit()
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .width(110)

                    TableColumn("Δ Pace") { split in
                        Text(split.formattedPaceDelta)
                            .monospacedDigit()
                            .foregroundStyle(deltaColor(split.paceDeltaSecondsPerKm))
                    }
                    .width(90)

                    TableColumn("Winner") { split in
                        Text(split.winner.label)
                            .font(.caption)
                    }
                    .width(80)
                }
            }
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        guard let d = delta else { return .secondary }
        if abs(d) < 5 { return .secondary }
        return d < 0 ? .green : .red
    }
}
