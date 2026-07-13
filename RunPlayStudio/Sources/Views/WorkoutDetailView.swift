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
    @FocusState private var isFocused: Bool

    init(workout: RunWorkout, appState: AppState) {
        self.workout = workout
        self.appState = appState
        self._replayController = ObservedObject(wrappedValue: appState.replayController)
    }

    enum ViewTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case charts = "Charts"
        case splits = "Splits"
        case segments = "Segments"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // GPS data warning banner
            if workout.routePoints.isEmpty {
                gpsWarningBanner
            }

            // Tab picker — subtle background instead of standalone
            tabPickerSection

            // Main content area (map or charts)
            mainContentArea

            // Bottom panels: segments, metrics, replay, summary
            bottomPanels
        }
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            switch press.characters {
            case "1": selectedTab = .overview; return .handled
            case "2": selectedTab = .charts; return .handled
            case "3": selectedTab = .splits; return .handled
            case "4": selectedTab = .segments; return .handled
            default: return .ignored
            }
        }
    }

    // MARK: - GPS Warning Banner

    private var gpsWarningBanner: some View {
        HStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: "location.slash")
                .foregroundStyle(AppDesign.warmYellow)
            Text("No GPS route data — only HR, cadence, and summary metrics are available.")
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.small)
        .background(AppDesign.warmYellow.opacity(0.08))
    }

    // MARK: - Tab Picker

    private var tabPickerSection: some View {
        HStack {
            Picker("View", selection: $selectedTab) {
                ForEach(ViewTab.allCases) { tab in
                    Text(tab.rawValue)
                        .tag(tab)
                        .help(tab == .overview
                              ? "Map and route visualization (⌘1)"
                              : tab == .charts
                              ? "Pace, HR, and elevation charts (⌘2)"
                              : tab == .splits
                              ? "Kilometer split table (⌘3)"
                              : "Auto-detected segments (⌘4)")
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

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
        case .splits:
            SplitTableView(
                splits: workout.splits,
                currentSplitIndex: currentSplitIndex
            )
            .padding(AppDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .segments:
            SegmentHighlightsPanel(
                segments: appState.detectedSegments,
                selectedSegment: $appState.selectedSegment,
                onSelect: { segment in
                    seekToSegment(segment)
                },
                onClear: {}
            )
            .padding(AppDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    /// Current split index based on replay distance.
    private var currentSplitIndex: Int? {
        let distance = replayController.state.currentDistance
        guard let idx = workout.splits.firstIndex(where: {
            distance >= $0.startDistanceMeters && distance < $0.endDistanceMeters
        }) else { return nil }
        return idx
    }
}
