import SwiftUI
import RunPlayCore

/// Compact panel showing metrics at the current replay position.
///
/// Updates in real-time during playback and scrubbing.
/// Each badge uses a semantic color from the design system to help
/// runners visually parse metrics at a glance.
struct CurrentMetricsPanel: View {
    let metrics: SelectedMetrics
    let hasHeartRate: Bool
    let hasCadence: Bool

    var body: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            MetricBadge(
                label: "Time",
                value: metrics.formattedElapsed,
                icon: "clock",
                color: AppDesign.MetricColor.duration
            )
            MetricBadge(
                label: "Distance",
                value: metrics.formattedDistance,
                icon: "ruler",
                color: AppDesign.MetricColor.distance
            )
            MetricBadge(
                label: "Pace",
                value: metrics.formattedPace,
                icon: "speedometer",
                color: AppDesign.MetricColor.pace
            )
            MetricBadge(
                label: "Elev",
                value: metrics.formattedElevation,
                icon: "mountain.2",
                color: AppDesign.MetricColor.elevation
            )

            if hasHeartRate {
                MetricBadge(
                    label: "HR",
                    value: metrics.formattedHeartRate,
                    icon: "heart.fill",
                    color: AppDesign.MetricColor.heartRate
                )
            }

            MetricBadge(
                label: "Split",
                value: metrics.formattedSplit,
                icon: "flag",
                color: AppDesign.MetricColor.split
            )
        }
    }
}

/// Single metric badge with label, value, and icon.
///
/// Uses generous sizing and semantic coloring for at-a-glance readability.
struct MetricBadge: View {
    let label: String
    let value: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: AppDesign.Spacing.xxSmall) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color.opacity(0.7))

            Text(value)
                .font(AppDesign.Typography.metricValue.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(AppDesign.Typography.metricLabel)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 56)
        .padding(.vertical, AppDesign.Spacing.xxSmall)
    }
}
