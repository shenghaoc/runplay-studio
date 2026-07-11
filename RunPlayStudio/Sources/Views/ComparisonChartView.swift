import SwiftUI
import RunPlayCore
import Charts


/// Chart showing pace comparison over distance.
///
/// Uses semantic colors from the design system for primary/comparison routes.
struct ComparisonChartView: View {
    let metrics: [ComparisonMetricPoint]
    let primaryName: String
    let comparisonName: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack(alignment: .lastTextBaseline) {
                Text("Pace Over Distance")
                    .font(AppDesign.Typography.sectionHeadline)
                Text("(lower is faster)")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
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
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            Text("Split Comparison")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)

            if splits.isEmpty {
                Text("No splits to compare")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
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
                                .foregroundStyle(AppDesign.primaryBlue)
                        } else {
                            Text("—")
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .width(90)

                    TableColumn("Comp. (min/km)") { split in
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

                    TableColumn("Δ Pace") { split in
                        Text(split.formattedPaceDelta)
                            .monospacedDigit()
                            .foregroundStyle(deltaColor(split.paceDeltaSecondsPerKm))
                    }
                    .width(90)

                    TableColumn("Winner") { split in
                        Text(split.winner.label)
                            .font(AppDesign.Typography.compactMetric)
                    }
                    .width(80)
                }
            }
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        guard let d = delta else { return .secondary }
        if abs(d) < 5 { return .secondary }
        return d < 0 ? AppDesign.energeticGreen : AppDesign.alertRed
    }
}
