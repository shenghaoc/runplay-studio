import SwiftUI

/// Main detail view for a selected workout showing 3D route, map, charts, and summary.
struct WorkoutDetailView: View {
    let workout: RunWorkout
    @ObservedObject var appState: AppState

    @State private var selectedTab: ViewTab = .route3D

    enum ViewTab: String, CaseIterable {
        case route3D = "3D Route"
        case map = "Map"
        case charts = "Charts"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("View", selection: $selectedTab) {
                ForEach(ViewTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // Main content
            switch selectedTab {
            case .route3D:
                Route3DReplayView(workout: workout, appState: appState)
            case .map:
                MapReferenceView(
                    routePoints: workout.routePoints,
                    currentPointIndex: appState.replayController.state.currentPointIndex
                )
            case .charts:
                MetricsChartView(
                    routePoints: workout.routePoints,
                    currentDistance: appState.replayController.state.currentDistance
                )
            }

            Divider()

            // Bottom panel: replay controls + summary
            HStack(spacing: 16) {
                // Replay controls
                ReplayControlsView(controller: appState.replayController)
                    .frame(maxWidth: .infinity)

                Divider()

                // Summary
                RunSummaryView(summary: workout.summary)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}
