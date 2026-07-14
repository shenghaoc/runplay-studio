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
            if !workout.analysisWarnings.isEmpty {
                analysisWarningBanner
            }

            WorkoutHeaderView(
                workout: workout,
                elevationAvailable: appState.analysisContext(for: workout)
                    .elevationProfile.hasMeaningfulElevation
            )

            Divider()

            VStack(spacing: AppDesign.Spacing.large) {
                TabBarView(selectedTab: $selectedTab)
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
        .focusedSceneValue(\.workoutTabSelection, $selectedTab)
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

    private var analysisWarningBanner: some View {
        HStack(alignment: .top, spacing: AppDesign.Spacing.small) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .foregroundStyle(AppDesign.warmYellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysis notes")
                    .font(AppDesign.Typography.secondary.weight(.semibold))
                ForEach(Array(workout.analysisWarnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning.message)
                        .font(AppDesign.Typography.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.small)
        .background(AppDesign.warmYellow.opacity(0.08))
        .accessibilityElement(children: .combine)
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
                elevationProfile: appState.analysisContext(for: workout).elevationProfile,
                currentDistance: replayController.state.currentDistance,
                onSeek: { distance in
                    replayController.pause()
                    replayController.seekToDistance(distance)
                }
            )
            .padding(.vertical, AppDesign.Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .panelBackground()
        case .splits:
            SplitTableView(
                splits: workout.splits,
                currentSplitIndex: replayController.selectedMetrics.splitIndex
            )
            .padding(AppDesign.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .panelBackground()
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
            .panelBackground()
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
            .frame(maxWidth: 620)

            Divider()
                .frame(height: 48)

            ReplayControlsView(controller: replayController)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
        .panelBackground()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func seekToSegment(_ segment: SegmentHighlight) {
        replayController.seekToDistance(segment.startDistanceMeters)
    }

}

// MARK: - Extracted Static Subviews

/// Workout metrics header — isolated from replay controller so SwiftUI skips
/// diffing this sub-tree during 30fps playback ticks.
private struct WorkoutHeaderView: View {
    let workout: RunWorkout
    let elevationAvailable: Bool

    var body: some View {
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

            headerMetric(
                "Distance",
                workout.summary.formattedDistance,
                AppDesign.MetricColor.distance,
                help: "Total recorded route distance."
            )
            headerMetric(
                "Elapsed",
                workout.summary.formattedElapsed,
                AppDesign.MetricColor.duration,
                help: "Elapsed time includes pauses and recording gaps."
            )
            headerMetric(
                "Active",
                workout.summary.formattedActive,
                AppDesign.MetricColor.duration,
                help: "Active time excludes recording gaps between route segments."
            )
            headerMetric(
                "Pace",
                workout.summary.formattedPace,
                AppDesign.MetricColor.pace,
                help: "Pace uses active time and excludes recording gaps."
            )
            headerMetric(
                "Elevation",
                elevationAvailable
                    ? DisplayFormatter.formatElevation(workout.summary.elevationGainMeters)
                    : "—",
                AppDesign.MetricColor.elevation,
                help: elevationAvailable
                    ? "Corrected, threshold-confirmed elevation gain."
                    : "Elevation analysis is unavailable for this workout."
            )
            if let heartRate = workout.summary.averageHeartRateBPM, heartRate.isFinite {
                headerMetric(
                    "Avg HR",
                    DisplayFormatter.formatHeartRate(heartRate),
                    AppDesign.MetricColor.heartRate,
                    help: "Average recorded heart rate."
                )
            }
        }
        .padding(.horizontal, AppDesign.Spacing.xxLarge)
        .padding(.vertical, AppDesign.Spacing.large)
        .background(AppDesign.panelBackground)
    }

    private func headerMetric(_ label: String, _ value: String, _ color: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(value)
                .font(AppDesign.Typography.metricLarge.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 72, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(help)
    }
}

/// Tab bar with contextual help — isolated from replay controller so SwiftUI
/// skips diffing this sub-tree during 30fps playback ticks.
private struct TabBarView: View {
    @Binding var selectedTab: WorkoutDetailView.ViewTab

    var body: some View {
        HStack {
            Picker("View", selection: $selectedTab) {
                ForEach(WorkoutDetailView.ViewTab.allCases) { tab in
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
}
