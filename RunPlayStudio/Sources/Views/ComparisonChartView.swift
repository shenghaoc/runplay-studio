import SwiftUI
import RunPlayCore
import Charts


/// Chart showing active-pace comparison over distance.
///
/// Uses semantic colors from the design system for primary/comparison routes.
struct ComparisonChartView: View {
    let metrics: [ComparisonMetricPoint]
    let primaryName: String
    let comparisonName: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack(alignment: .lastTextBaseline) {
                Text("Active Pace Over Distance")
                    .font(AppDesign.Typography.sectionHeadline)
                Text("(lower is faster)")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
            .help("Pace uses active time and excludes recording gaps.")

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
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }

                        if let comparisonPace = point.comparisonPace, comparisonPace.isFinite {
                            LineMark(
                                x: .value("Distance (km)", point.distanceKm),
                                y: .value("min/km", comparisonPace)
                            )
                            .foregroundStyle(by: .value("Run", comparisonName))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                .chartForegroundStyleScale([
                    primaryName: AppDesign.primaryBlue,
                    comparisonName: AppDesign.comparisonOrange
                ])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisValueLabel {
                            if let km = value.as(Double.self) {
                                Text("\(Int(km)) km")
                            }
                        }
                        AxisGridLine()
                            .foregroundStyle(.quaternary)
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
                            .foregroundStyle(.quaternary)
                    }
                }
                .chartLegend(position: .bottom) {
                    HStack(spacing: AppDesign.Spacing.xLarge) {
                        Label(truncatedName(primaryName), systemImage: "circle.fill")
                            .foregroundStyle(AppDesign.primaryBlue)
                            .font(AppDesign.Typography.compactMetric)
                        Label(truncatedName(comparisonName), systemImage: "circle.fill")
                            .foregroundStyle(AppDesign.comparisonOrange)
                            .font(AppDesign.Typography.compactMetric)
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
        VStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No pace data to chart")
                .font(AppDesign.Typography.secondary)
                .foregroundStyle(.secondary)
            Text("Both runs need GPS route points with timing data to build a pace comparison.")
                .font(AppDesign.Typography.compactMetric)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Split Comparison Table

struct SplitComparisonTableView: View {
    let splits: [SplitComparison]

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text("Split Active Pace (min/km)")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)
                .help("Split comparison uses active time and excludes recording gaps.")

            if splits.isEmpty {
                Text("No splits to compare")
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Table(splits) {
                    TableColumn("km") { split in
                        Text("\(split.splitIndex)")
                            .monospacedDigit()
                    }
                    .width(35)

                    TableColumn("Selected") { split in
                        if let s = split.primarySplit {
                            Text(s.formattedPace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.primaryBlue)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(90)

                    TableColumn("Comparison") { split in
                        if let s = split.comparisonSplit {
                            Text(s.formattedPace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.comparisonOrange)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(110)

                    TableColumn("Δ") { split in
                        HStack(spacing: AppDesign.Spacing.xxSmall) {
                            Image(systemName: winnerIcon(for: split.winner))
                                .font(AppDesign.Typography.compactLabel)
                                .accessibilityHidden(true)
                            Text(split.formattedPaceDelta)
                                .monospacedDigit()
                        }
                        .foregroundStyle(deltaColor(split.paceDeltaSecondsPerKm))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "Active pace difference \(split.formattedPaceDelta); \(split.winner.label)"
                        )
                    }
                    .width(110)
                }
            }
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        AppDesign.deltaColor(delta, threshold: 5)
    }

    private func winnerIcon(for result: RunPlayCore.ComparisonResult) -> String {
        switch result {
        case .primary: return "1.circle.fill"
        case .comparison: return "2.circle.fill"
        case .tie: return "equal.circle.fill"
        case .unavailable: return "questionmark.circle"
        }
    }

}

/// Ordinal recorded-lap comparison. Does not claim route alignment.
struct RecordedLapComparisonTableView: View {
    let comparisons: [RecordedLapComparison]

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text("Recorded Laps (ordinal)")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)
                .help("Pairs lap 1 with lap 1 only. This is not a route-aligned comparison.")

            if let caveat = comparisons.flatMap(\.caveats).first {
                Text(caveat)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if comparisons.isEmpty {
                Text("No recorded laps to compare")
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.tertiary)
            } else {
                Table(comparisons) {
                    TableColumn("Lap") { row in
                        Text("\(row.lapIndex)")
                            .monospacedDigit()
                    }
                    .width(40)

                    TableColumn("Selected") { row in
                        if let lap = row.primaryLap {
                            Text(lap.formattedActivePace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.primaryBlue)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(90)

                    TableColumn("Comparison") { row in
                        if let lap = row.comparisonLap {
                            Text(lap.formattedActivePace)
                                .monospacedDigit()
                                .foregroundStyle(AppDesign.comparisonOrange)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(110)

                    TableColumn("Δ Active") { row in
                        Text(row.formattedActivePaceDelta)
                            .monospacedDigit()
                            .foregroundStyle(AppDesign.deltaColor(row.activePaceDeltaSecondsPerKm, threshold: 5))
                    }
                    .width(100)
                }
                .frame(minHeight: 120)
            }
        }
    }
}
