import SwiftUI
import RunPlayCore

/// Displays a summary of the running workout metrics.
///
/// Uses a compact grid layout with semantic color accents for each metric type.
struct RunSummaryView: View {
    let summary: RunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Summary")
                .font(AppDesign.Typography.sectionHeadline)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: AppDesign.Spacing.xLarge, verticalSpacing: AppDesign.Spacing.small) {
                GridRow {
                    MetricLabel(label: "Distance", value: summary.formattedDistance, color: AppDesign.MetricColor.distance)
                    MetricLabel(label: "Duration", value: summary.formattedDuration, color: AppDesign.MetricColor.duration)
                }
                GridRow {
                    MetricLabel(label: "Avg Pace", value: summary.formattedPace, color: AppDesign.MetricColor.pace)
                    MetricLabel(
                        label: "Avg Speed",
                        value: DisplayFormatter.formatSpeedKmh(summary.averageSpeedMetersPerSecond),
                        color: AppDesign.MetricColor.speed
                    )
                }
                GridRow {
                    MetricLabel(
                        label: "Elev Gain",
                        value: DisplayFormatter.formatElevation(summary.elevationGainMeters),
                        color: AppDesign.MetricColor.elevation
                    )
                    MetricLabel(
                        label: "Elev Loss",
                        value: DisplayFormatter.formatElevation(summary.elevationLossMeters),
                        color: AppDesign.softPurple
                    )
                }

                if let avgHR = summary.averageHeartRateBPM, avgHR.isFinite {
                    GridRow {
                        MetricLabel(
                            label: "Avg HR",
                            value: DisplayFormatter.formatHeartRate(avgHR),
                            color: AppDesign.MetricColor.heartRate
                        )
                        if let maxHR = summary.maxHeartRateBPM, maxHR.isFinite {
                            MetricLabel(
                                label: "Max HR",
                                value: DisplayFormatter.formatHeartRate(maxHR),
                                color: AppDesign.MetricColor.heartRate
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Metric Label

struct MetricLabel: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(AppDesign.Typography.metricValue.monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
