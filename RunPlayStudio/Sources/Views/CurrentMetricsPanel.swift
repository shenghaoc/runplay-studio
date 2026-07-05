import SwiftUI

/// Compact panel showing metrics at the current replay position.
///
/// Updates in real-time during playback and scrubbing.
struct CurrentMetricsPanel: View {
    let metrics: SelectedMetrics
    let hasHeartRate: Bool
    let hasCadence: Bool

    var body: some View {
        HStack(spacing: 16) {
            MetricBadge(label: "Time", value: metrics.formattedElapsed, icon: "clock")
            MetricBadge(label: "Distance", value: metrics.formattedDistance, icon: "ruler")
            MetricBadge(label: "Pace", value: metrics.formattedPace, icon: "speedometer")
            MetricBadge(label: "Elev", value: metrics.formattedElevation, icon: "mountain.2")

            if hasHeartRate {
                MetricBadge(label: "HR", value: metrics.formattedHeartRate, icon: "heart.fill", color: .red)
            }

            MetricBadge(label: "Split", value: metrics.formattedSplit, icon: "flag")
        }
    }
}

/// Single metric badge with label, value, and icon.
struct MetricBadge: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 50)
    }
}
