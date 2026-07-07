import SwiftUI
import RunPlayCore

/// Overview tab showing a real map with route overlay, summary, and replay controls.
///
/// This is the default landing view — it presents the run in a map context
/// so the user immediately sees a recognizable map/route experience.
struct OverviewView: View {
    let workout: RunWorkout
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Map takes up the main area
            MapReferenceView(
                routePoints: workout.routePoints,
                currentPointIndex: appState.replayController.state.currentPointIndex
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Summary metrics bar
            HStack(spacing: 16) {
                MetricBadge(label: "Distance", value: workout.summary.formattedDistance, icon: "figure.run")
                MetricBadge(label: "Duration", value: workout.summary.formattedDuration, icon: "clock")
                MetricBadge(label: "Pace", value: workout.summary.formattedPace, icon: "speedometer")
                MetricBadge(
                    label: "Elev",
                    value: String(format: "+%.0f m", workout.summary.elevationGainMeters),
                    icon: "mountain.2"
                )

                if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite {
                    MetricBadge(
                        label: "Avg HR",
                        value: String(format: "%.0f bpm", avgHR),
                        icon: "heart.fill",
                        color: .red
                    )
                }

                Divider().frame(height: 20)

                // Replay controls inline
                ReplayControlsView(controller: appState.replayController)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }
}
