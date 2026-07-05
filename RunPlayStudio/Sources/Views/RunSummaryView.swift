import SwiftUI

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
                        value: String(format: "%.1f km/h", summary.averageSpeedMetersPerSecond * 3.6)
                    )
                }
                GridRow {
                    MetricLabel(
                        label: "Elev Gain",
                        value: String(format: "%.0f m", summary.elevationGainMeters)
                    )
                    MetricLabel(
                        label: "Elev Loss",
                        value: String(format: "%.0f m", summary.elevationLossMeters)
                    )
                }

                if let avgHR = summary.averageHeartRateBPM {
                    GridRow {
                        MetricLabel(label: "Avg HR", value: "\(Int(avgHR)) bpm")
                        if let maxHR = summary.maxHeartRateBPM {
                            MetricLabel(label: "Max HR", value: "\(Int(maxHR)) bpm")
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
