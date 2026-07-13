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
            MetricDisplay(label: "Time", value: metrics.formattedElapsed, icon: "clock", color: AppDesign.MetricColor.duration)
            MetricDisplay(label: "Distance", value: metrics.formattedDistance, icon: "ruler", color: AppDesign.MetricColor.distance)
            MetricDisplay(label: "Pace", value: metrics.formattedPace, icon: "speedometer", color: AppDesign.MetricColor.pace)
            MetricDisplay(label: "Elev", value: metrics.formattedElevation, icon: "mountain.2", color: AppDesign.MetricColor.elevation)

            if hasHeartRate {
                MetricDisplay(label: "HR", value: metrics.formattedHeartRate, icon: "heart.fill", color: AppDesign.MetricColor.heartRate)
            }

            MetricDisplay(label: "Split", value: metrics.formattedSplit, icon: "flag", color: AppDesign.MetricColor.split)
        }
    }
}
