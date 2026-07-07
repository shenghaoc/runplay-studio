import SwiftUI
import RunPlayCore

/// Displays a summary of the running workout metrics.
struct RunSummaryView: View {
    let summary: RunSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    MetricLabel(label: "Distance", value: summary.formattedDistance)
                    MetricLabel(label: "Duration", value: summary.formattedDuration)
                }
                GridRow {
                    MetricLabel(label: "Avg Pace", value: summary.formattedPace)
                    MetricLabel(
                        label: "Avg Speed",
                        value: DisplayFormatter.formatSpeedKmh(summary.averageSpeedMetersPerSecond)
                    )
                }
                GridRow {
                    MetricLabel(
                        label: "Elev Gain",
                        value: DisplayFormatter.formatElevation(summary.elevationGainMeters)
                    )
                    MetricLabel(
                        label: "Elev Loss",
                        value: DisplayFormatter.formatElevation(summary.elevationLossMeters)
                    )
                }

                if let avgHR = summary.averageHeartRateBPM, avgHR.isFinite {
                    GridRow {
                        MetricLabel(label: "Avg HR", value: DisplayFormatter.formatHeartRate(avgHR))
                        if let maxHR = summary.maxHeartRateBPM, maxHR.isFinite {
                            MetricLabel(label: "Max HR", value: DisplayFormatter.formatHeartRate(maxHR))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
        }
    }
}
