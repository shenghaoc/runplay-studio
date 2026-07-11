import SwiftUI
import RunPlayCore

/// Main detail view for a selected workout showing Apple Maps, charts, and summary.
///
/// Uses grouped backgrounds instead of divider-heavy layouts to create
/// visual hierarchy without clutter.
struct WorkoutDetailView: View {
    let workout: RunWorkout
    @ObservedObject var appState: AppState
    @ObservedObject private var replayController: ReplayController

    @State private var selectedTab: ViewTab = .overview

    init(workout: RunWorkout, appState: AppState) {
        self.workout = workout
        self.appState = appState
        self._replayController = ObservedObject(wrappedValue: appState.replayController)
    }

    enum ViewTab: String, CaseIterable {
        case overview = "Overview"
        case charts = "Charts"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker — subtle background instead of standalone
            tabPickerSection

            // Main content area (map or charts)
            mainContentArea

            // Bottom panels: segments, metrics, replay, summary
            bottomPanels
        }
    }

    // MARK: - Tab Picker

    private var tabPickerSection: some View {
        HStack {
            Picker("View", selection: $selectedTab) {
                ForEach(ViewTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)

            Spacer()
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
        .background(AppDesign.panelBackground)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentArea: some View {
        switch selectedTab {
        case .overview:
            OverviewView(
                workout: workout,
                currentPointIndex: replayController.state.currentPointIndex
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .charts:
            MetricsChartView(
                routePoints: workout.routePoints,
                currentDistance: replayController.state.currentDistance,
                onSeek: { distance in
                    replayController.pause()
                    replayController.seekToDistance(distance)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Bottom Panels

    private var bottomPanels: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            // Segment highlights (if any)
            if !appState.detectedSegments.isEmpty {
                SegmentHighlightsPanel(
                    segments: appState.detectedSegments,
                    selectedSegment: $appState.selectedSegment,
                    onSelect: { segment in
                        seekToSegment(segment)
                    },
                    onClear: {}
                )
                .padding(.horizontal, AppDesign.Spacing.xLarge)
                .padding(.vertical, AppDesign.Spacing.small)
                .background(AppDesign.panelBackground)
            }

            // Current metrics panel
            CurrentMetricsPanel(
                metrics: replayController.selectedMetrics,
                hasHeartRate: workout.hasHeartRateData,
                hasCadence: workout.hasCadenceData
            )
            .padding(.horizontal, AppDesign.Spacing.xLarge)
            .padding(.vertical, AppDesign.Spacing.small)
            .background(AppDesign.panelBackground)

            // Replay controls + summary
            HStack(spacing: AppDesign.Spacing.xLarge) {
                ReplayControlsView(controller: replayController)
                    .frame(maxWidth: .infinity)

                Divider()
                    .padding(.vertical, AppDesign.Spacing.xSmall)

                RunSummaryView(summary: workout.summary)
                    .frame(maxWidth: .infinity)
            }
            .padding(AppDesign.Spacing.xLarge)
            .background(AppDesign.panelBackground)
        }
    }

    private func seekToSegment(_ segment: SegmentHighlight) {
        replayController.seekToDistance(segment.startDistanceMeters)
    }
}
