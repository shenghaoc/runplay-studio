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
            MetricDisplay(label: "Elapsed", value: metrics.formattedElapsed, icon: "clock", color: AppDesign.MetricColor.duration)
                .help("Elapsed time follows the replay clock and includes recording gaps.")
            MetricDisplay(label: "Active", value: metrics.formattedActive, icon: "timer", color: AppDesign.MetricColor.duration)
                .help("Active time remains fixed during recording gaps.")
            MetricDisplay(label: "Moving (est.)", value: metrics.formattedMoving, icon: "figure.run", color: AppDesign.MetricColor.duration)
                .help("Moving time is estimated from route movement. Uncertain active time counts as moving.")
            MetricDisplay(label: "Stopped (est.)", value: metrics.formattedStopped, icon: "figure.stand", color: .secondary)
                .help("Stopped time is an estimate of stationary active recording time.")
            MetricDisplay(label: "Distance", value: metrics.formattedDistance, icon: "ruler", color: AppDesign.MetricColor.distance)
            MetricDisplay(label: "Pace", value: metrics.formattedPace, icon: "speedometer", color: AppDesign.MetricColor.pace)
                .help("Pace uses active time.")
            MetricDisplay(label: "Elev", value: metrics.formattedElevation, icon: "mountain.2", color: AppDesign.MetricColor.elevation)

            if hasHeartRate {
                MetricDisplay(label: "HR", value: metrics.formattedHeartRate, icon: "heart.fill", color: AppDesign.MetricColor.heartRate)
            }

            if hasCadence {
                MetricDisplay(label: "Cad", value: metrics.formattedCadence, icon: "shoeprints.fill", color: AppDesign.MetricColor.cadence)
            }

            MetricDisplay(label: "Split", value: metrics.formattedSplit, icon: "flag", color: AppDesign.MetricColor.split)

            if metrics.isInRecordingGap {
                Label("Paused", systemImage: "pause.fill")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(AppDesign.comparisonOrange)
                    .padding(.horizontal, AppDesign.Spacing.small)
                    .padding(.vertical, AppDesign.Spacing.xSmall)
                    .background(AppDesign.comparisonOrange.opacity(0.12), in: Capsule())
                    .help("Recording gap: elapsed time is advancing while active time and distance remain fixed.")
                    .accessibilityLabel("Paused")
                    .accessibilityHint("Recording gap: elapsed time is advancing while active time and distance remain fixed")
            }

            if let state = metrics.movementState, !metrics.isInRecordingGap {
                Label(metrics.movementStateLabel, systemImage: state == .stopped ? "stop.circle.fill" : "figure.run")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(state == .stopped ? AppDesign.comparisonOrange : .secondary)
                    .accessibilityLabel(String(
                        format: NSLocalizedString(
                            "Estimated movement state: %@",
                            comment: "Accessibility label for movement state"
                        ),
                        metrics.movementStateLabel
                    ))
            }
        }
    }
}
