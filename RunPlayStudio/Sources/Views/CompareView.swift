import SwiftUI
import RunPlayCore

/// Main comparison view showing two workouts side by side.
///
/// Uses the design system's comparison orange for visual identity
/// and improved spacing throughout.
struct CompareView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            comparisonSelector
            Divider()

            if let pair = appState.comparisonPair {
                VStack(spacing: AppDesign.Spacing.large) {
                    if let summary = appState.comparisonSummary {
                        ComparisonSummaryView(summary: summary)
                    }

                    alignmentControls

                    HStack(spacing: AppDesign.Spacing.large) {
                        ComparisonMapView(
                            primaryWorkout: pair.primary,
                            comparisonWorkout: pair.comparison,
                            warnings: appState.comparisonDisplayWarnings,
                            appState: appState
                        )
                        .layoutPriority(1)
                        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))

                        VStack(spacing: AppDesign.Spacing.large) {
                            SplitComparisonTableView(
                                splits: appState.splitComparisons,
                                isRouteAwareMode: appState.comparisonViewModel.alignmentMode == .routeAware
                            )
                            if !appState.recordedLapComparisons.isEmpty {
                                RecordedLapComparisonTableView(
                                    comparisons: appState.recordedLapComparisons
                                )
                            }
                        }
                        .padding(AppDesign.Spacing.large)
                        .frame(minWidth: 380, maxWidth: 480, maxHeight: .infinity)
                        .panelBackground()
                    }
                    .layoutPriority(1)

                    ComparisonChartView(
                        metrics: appState.comparisonMetrics,
                        alignedMetrics: appState.comparisonViewModel.alignedChartPoints,
                        alignmentMode: appState.comparisonViewModel.alignmentMode,
                        isRouteAwareReady: appState.comparisonViewModel.isRouteAwareReady,
                        primaryName: pair.primary.displayName,
                        comparisonName: pair.comparison.displayName
                    )
                    .padding(AppDesign.Spacing.large)
                    .frame(height: 190)
                    .panelBackground()
                }
                .padding(AppDesign.Spacing.large)
            } else {
                ComparisonEmptyView(
                    workoutCount: appState.workouts.count,
                    primaryName: appState.selectedWorkout?.displayName,
                    onImport: { appState.showImporter = true }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppDesign.workspaceBackground)
        .onChange(of: appState.selectedComparisonDistanceMeters) { _, _ in
            appState.requestSessionSave()
        }
        .onChange(of: appState.comparisonViewModel.selectedAlignedProgressMeters) { _, _ in
            appState.requestSessionSave()
        }
        .onChange(of: appState.comparisonViewModel.alignmentMode) { _, _ in
            appState.requestSessionSave()
        }
    }

    // MARK: - Alignment controls

    private var alignmentControls: some View {
        let vm = appState.comparisonViewModel
        return VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack(spacing: AppDesign.Spacing.large) {
                Text("Alignment")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)

                Picker("Alignment", selection: Binding(
                    get: { vm.alignmentMode },
                    set: { appState.setComparisonAlignmentMode($0) }
                )) {
                    ForEach(ComparisonAlignmentMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .help(vm.alignmentMode.helpText)
                .accessibilityLabel("Comparison alignment mode")
                .accessibilityValue(vm.alignmentMode.displayName)
                .accessibilityHint(vm.alignmentMode.helpText)

                Text(vm.alignmentMode.helpText)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }

            if vm.alignmentMode == .routeAware {
                routeAwareStatusPanel
            }
        }
        .padding(AppDesign.Spacing.large)
        .panelBackground()
    }

    @ViewBuilder
    private var routeAwareStatusPanel: some View {
        let vm = appState.comparisonViewModel
        switch vm.routeAlignmentLoadState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: AppDesign.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("Aligning routes…")
                    .font(AppDesign.Typography.compactMetric)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Aligning routes")
        case .ready:
            if let snapshot = vm.routeAlignmentSnapshot,
               case .available(let quality) = snapshot.availability {
                HStack(spacing: AppDesign.Spacing.medium) {
                    Label(
                        "\(quality.displayName) · \(snapshot.diagnostics.compactStatusLabel)",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                    .font(AppDesign.Typography.compactMetric)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Route alignment \(quality.displayName). \(snapshot.diagnostics.compactStatusLabel)"
                )
            }
        case .unavailable(let reason):
            HStack(alignment: .top, spacing: AppDesign.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppDesign.comparisonOrange)
                VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
                    Text(reason.userFacingExplanation)
                        .font(AppDesign.Typography.compactMetric)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Use Distance Alignment") {
                        appState.setComparisonAlignmentMode(.distance)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Use Distance Alignment")
                }
                Spacer(minLength: 0)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: AppDesign.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppDesign.comparisonOrange)
                VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
                    Text(message)
                        .font(AppDesign.Typography.compactMetric)
                        .foregroundStyle(.secondary)
                    Button("Use Distance Alignment") {
                        appState.setComparisonAlignmentMode(.distance)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Selector

    private var comparisonSelector: some View {
        ViewThatFits(in: .horizontal) {
            // Wide layout
            wideComparisonSelector
            // Compact layout
            compactComparisonSelector
        }
    }

    private var wideComparisonSelector: some View {
        HStack(spacing: AppDesign.Spacing.xxLarge) {
            Text("COMPARE")
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            workoutLabel("My Run", name: appState.selectedWorkout?.displayName ?? "None")

            Spacer(minLength: AppDesign.Spacing.large)

            Image(systemName: "arrow.left.arrow.right")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppDesign.comparisonOrange)

            comparisonPickerSection

            Spacer()

            clearButton
        }
        .padding(.horizontal, AppDesign.Spacing.xxLarge)
        .padding(.vertical, AppDesign.Spacing.large)
        .background(AppDesign.panelBackground)
    }

    private var compactComparisonSelector: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            HStack {
                workoutLabel("My Run", name: appState.selectedWorkout?.displayName ?? "None")
                Spacer()
                clearButton
            }

            HStack {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppDesign.comparisonOrange)
                Text("vs.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }

            comparisonPickerSection
        }
        .padding(.horizontal, AppDesign.Spacing.xxLarge)
        .padding(.vertical, AppDesign.Spacing.large)
        .background(AppDesign.panelBackground)
    }

    private func workoutLabel(_ role: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(role)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Text(name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .help("Your selected run for comparison")
        }
    }

    private var comparisonPickerSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text("Compare With")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            if appState.availableForComparison.isEmpty {
                if appState.workouts.count < 2 {
                    Button(action: { appState.showImporter = true }) {
                        Label("Import another run", systemImage: "doc.badge.plus")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Import another run to compare")
                    .accessibilityLabel("Import another run")
                } else {
                    Text("No other workouts")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Picker("Compare With", selection: Binding(
                    get: { appState.comparisonWorkout },
                    set: { appState.setComparison($0) }
                )) {
                    Text("Select workout").tag(nil as RunWorkout?)
                    ForEach(appState.availableForComparison) { workout in
                        Text(workout.displayName).tag(workout as RunWorkout?)
                    }
                }
                .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
                .help("Choose another run to compare")
            }

            if let message = appState.comparisonSelectionMessage {
                Text(message)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(AppDesign.comparisonOrange)
            }
        }
    }

    private var clearButton: some View {
        Group {
            if appState.isComparing {
                Button("Clear") {
                    appState.clearComparison()
                }
                .font(AppDesign.Typography.compactMetric)
                .controlSize(.regular)
                .help("Exit comparison mode and return to single-workout view")
                .accessibilityLabel("Clear Comparison")
            }
        }
    }
}

// MARK: - Comparison Summary

struct ComparisonSummaryView: View {
    let summary: WorkoutComparisonSummary

    var body: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
                HStack(spacing: AppDesign.Spacing.small) {
                    Image(systemName: winnerIcon)
                        .foregroundStyle(winnerColor)
                    Text(summary.winner.label)
                        .font(.headline)
                        .foregroundStyle(winnerColor)
                }

                Text("ACTIVE PACE RESULT")
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 150, alignment: .leading)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: AppDesign.Spacing.small)],
                spacing: AppDesign.Spacing.small
            ) {
                DeltaCard(label: "Distance", value: summary.distanceDeltaFormatted)
                DeltaCard(label: "Active Time", value: summary.activeTimeDeltaFormatted)
                    .help("Active time excludes recording gaps.")
                DeltaCard(label: "Elapsed Time", value: summary.elapsedTimeDeltaFormatted)
                    .help("Elapsed time includes pauses and recording gaps.")
                DeltaCard(label: "Paused", value: summary.pausedTimeDeltaFormatted)
                    .help("Paused time is elapsed time minus active time.")
                DeltaCard(label: "Moving (est.)", value: summary.movingTimeDeltaFormatted)
                    .help("Moving time is estimated from route movement. Uncertain active time counts as moving.")
                DeltaCard(label: "Stopped (est.)", value: summary.stoppedTimeDeltaFormatted)
                    .help("Stopped time is estimated from stationary active recording time.")
                DeltaCard(label: "Active Pace", value: summary.paceDeltaFormatted)
                    .help("Pace is calculated from active time.")
                DeltaCard(label: "Moving Pace (est.)", value: summary.movingPaceDeltaFormatted)
                    .help("Moving pace is estimated from moving time and does not replace active pace.")
                DeltaCard(label: "Elevation", value: summary.elevationGainDeltaFormatted)
                if let avgHR = summary.avgHRDeltaFormatted {
                    DeltaCard(label: "Avg HR", value: avgHR)
                }
            }
            .frame(maxWidth: .infinity)

            if summary.warnings.contains(where: {
                $0 == .differentDistances
                    || $0 == .differentRouteShape
                    || $0 == .insufficientOverlap
                    || $0 == .differentPauseDurations
            }) {
                HStack(spacing: AppDesign.Spacing.small) {
                    Image(systemName: "info.circle")
                    Text("Aligned over \(commonDistanceLabel)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesign.Spacing.large)
        .panelBackground()
    }

    private var winnerIcon: String {
        switch summary.winner {
        case .primary: return "checkmark.circle.fill"
        case .comparison: return "xmark.circle.fill"
        case .tie: return "equal.circle.fill"
        case .unavailable: return "questionmark.circle"
        }
    }

    private var winnerColor: Color {
        switch summary.winner {
        case .primary: return AppDesign.energeticGreen
        case .comparison: return AppDesign.alertRed
        case .tie: return .secondary
        case .unavailable: return .secondary
        }
    }

    private var commonDistanceLabel: String {
        let commonKm = min(summary.primaryDistanceMeters, summary.comparisonDistanceMeters) / 1000
        return String(format: "%.1f km", commonKm)
    }
}

struct DeltaCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: AppDesign.Spacing.xxSmall) {
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(AppDesign.Typography.metricValue.monospacedDigit())
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppDesign.Spacing.medium)
        .padding(.vertical, AppDesign.Spacing.small)
        .background(AppDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
    }
}

// MARK: - Comparison Empty State

struct ComparisonEmptyView: View {
    let workoutCount: Int
    let primaryName: String?
    let onImport: @MainActor () -> Void

    var body: some View {
        VStack(spacing: AppDesign.Spacing.xLarge) {
            Image(systemName: "arrow.left.arrow.right")
                .font(AppDesign.Typography.emptyStateIcon)
                .foregroundStyle(.tertiary)

            Text(title)
                .font(AppDesign.Typography.heading3)

            Text(message)
                .font(AppDesign.Typography.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if workoutCount < 2 {
                Button(action: onImport) {
                    Label("Import File", systemImage: "doc.badge.plus")
                        .font(AppDesign.Typography.bodySemibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Select a file to import and compare")
                .accessibilityLabel("Import run")
            } else if primaryName != nil {
                Text("Use the \"Compare With\" picker above to select a second run.")
                    .font(AppDesign.Typography.compactMetric)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if workoutCount < 2 { return "Import another run to compare" }
        if primaryName == nil { return "Select a primary run" }
        return "Select a comparison run"
    }

    private var message: String {
        if workoutCount == 0 { return "No runs loaded yet. Import a GPX, TCX, FIT, or JSON file to get started." }
        if workoutCount == 1 { return "Only one run is loaded. Import another to compare side-by-side." }
        if let primaryName { return "Primary: \(primaryName)" }
        return "Choose a run in the sidebar to begin"
    }
}
