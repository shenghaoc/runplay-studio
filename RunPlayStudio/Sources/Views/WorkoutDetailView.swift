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

            workoutHeader

            Divider()

            VStack(spacing: AppDesign.Spacing.large) {
                tabPickerSection
                mainContentArea
                    .layoutPriority(1)
                replayDock
            }
            .padding(AppDesign.Spacing.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AppDesign.workspaceBackground
                .ignoresSafeArea()
        }
        .focused($isFocused)
        .focusable()
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

    // MARK: - Workout Header

    private var workoutHeader: some View {
        HStack(alignment: .center, spacing: AppDesign.Spacing.xxxLarge) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text("WORKOUT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
                Text(workout.displayName)
                    .font(AppDesign.Typography.heading2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 260, alignment: .leading)
            .help(workout.displayName)

            Spacer(minLength: AppDesign.Spacing.xLarge)

            headerMetric("Distance", workout.summary.formattedDistance, AppDesign.MetricColor.distance)
            headerMetric("Duration", workout.summary.formattedDuration, AppDesign.MetricColor.duration)
            headerMetric("Avg Pace", workout.summary.formattedPace, AppDesign.MetricColor.pace)
            headerMetric(
                "Elevation",
                DisplayFormatter.formatElevation(workout.summary.elevationGainMeters),
                AppDesign.MetricColor.elevation
            )
            if let heartRate = workout.summary.averageHeartRateBPM, heartRate.isFinite {
                headerMetric("Avg HR", DisplayFormatter.formatHeartRate(heartRate), AppDesign.MetricColor.heartRate)
            }
        }
        .padding(.horizontal, AppDesign.Spacing.xxLarge)
        .padding(.vertical, AppDesign.Spacing.large)
        .background(AppDesign.panelBackground)
    }

    private func headerMetric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(value)
                .font(AppDesign.Typography.metricLarge.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 72, alignment: .leading)
    }

    // MARK: - GPS Warning Banner

    private var gpsWarningBanner: some View {
        HStack(spacing: AppDesign.Spacing.small) {
            Image(systemName: "location.slash")
                .foregroundStyle(AppDesign.warmYellow)
            Text("No GPS route data — only HR, cadence, and summary metrics are available.")
                .font(AppDesign.Typography.secondary)
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

            Spacer()

            Text(tabContext)
                .font(AppDesign.Typography.compactMetric)
                .foregroundStyle(.tertiary)
        }
    }

    private var tabContext: String {
        switch selectedTab {
        case .overview: return "Route replay"
        case .charts: return "Drag the chart to navigate"
        case .splits: return "Kilometer breakdown"
        case .segments: return "Detected highlights"
        }
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
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
        case .charts:
            MetricsChartView(
                routePoints: workout.routePoints,
                currentDistance: replayController.state.currentDistance,
                onSeek: { distance in
                    replayController.pause()
                    replayController.seekToDistance(distance)
                }
            )
            .padding(.vertical, AppDesign.Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppDesign.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
        case .splits:
            SplitTableView(
                splits: workout.splits,
                currentSplitIndex: currentSplitIndex
            )
            .padding(AppDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AppDesign.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
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
            .background(AppDesign.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
        }
    }

    // MARK: - Replay Dock

    private var replayDock: some View {
        HStack(spacing: AppDesign.Spacing.xxLarge) {
            CurrentMetricsPanel(
                metrics: replayController.selectedMetrics,
                hasHeartRate: workout.hasHeartRateData,
                hasCadence: workout.hasCadenceData
            )
            .frame(maxWidth: 460)

            Divider()
                .frame(height: 48)

            ReplayControlsView(controller: replayController)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
        .background(AppDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func seekToSegment(_ segment: SegmentHighlight) {
        replayController.seekToDistance(segment.startDistanceMeters)
    }

    /// Current split index based on replay distance.
    private var currentSplitIndex: Int? {
        let distance = replayController.state.currentDistance
        guard let idx = workout.splits.firstIndex(where: {
            distance >= $0.startDistanceMeters
                && (distance < $0.endDistanceMeters || $0.id == workout.splits.last?.id)
        }) else { return nil }
        return idx
    }
}
