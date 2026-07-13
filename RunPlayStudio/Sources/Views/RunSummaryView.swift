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
                    MetricDisplay(label: "Distance", value: summary.formattedDistance, color: AppDesign.MetricColor.distance, layout: .leading)
                    MetricDisplay(label: "Duration", value: summary.formattedDuration, color: AppDesign.MetricColor.duration, layout: .leading)
                }
                GridRow {
                    MetricDisplay(label: "Avg Pace", value: summary.formattedPace, color: AppDesign.MetricColor.pace, layout: .leading)
                    MetricDisplay(
                        label: "Avg Speed",
                        value: DisplayFormatter.formatSpeedKmh(summary.averageSpeedMetersPerSecond),
                        color: AppDesign.MetricColor.speed,
                        layout: .leading
                    )
                }
                GridRow {
                    MetricDisplay(
                        label: "Elevation Gain",
                        value: DisplayFormatter.formatElevation(summary.elevationGainMeters),
                        color: AppDesign.MetricColor.elevation,
                        layout: .leading
                    )
                    MetricDisplay(
                        label: "Elevation Loss",
                        value: DisplayFormatter.formatElevation(summary.elevationLossMeters),
                        color: AppDesign.softPurple,
                        layout: .leading
                    )
                }

                if let avgHR = summary.averageHeartRateBPM, avgHR.isFinite {
                    GridRow {
                        MetricDisplay(
                            label: "Avg HR",
                            value: DisplayFormatter.formatHeartRate(avgHR),
                            color: AppDesign.MetricColor.heartRate,
                            layout: .leading
                        )
                        if let maxHR = summary.maxHeartRateBPM, maxHR.isFinite {
                            MetricDisplay(
                                label: "Max HR",
                                value: DisplayFormatter.formatHeartRate(maxHR),
                                color: AppDesign.MetricColor.heartRate,
                                layout: .leading
                            )
                        }
                    }
                }
            }
        }
    }
}
