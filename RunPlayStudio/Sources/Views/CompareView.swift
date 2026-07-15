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

                    HStack(spacing: AppDesign.Spacing.large) {
                        ComparisonMapView(
                            primaryWorkout: pair.primary,
                            comparisonWorkout: pair.comparison,
                            warnings: appState.comparisonSummary?.warnings ?? [],
                            appState: appState
                        )
                        .layoutPriority(1)
                        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))

                        SplitComparisonTableView(splits: appState.splitComparisons)
                            .padding(AppDesign.Spacing.large)
                            .frame(minWidth: 380, maxWidth: 480, maxHeight: .infinity)
                            .panelBackground()
                    }
                    .layoutPriority(1)

                    ComparisonChartView(
                        metrics: appState.comparisonMetrics,
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
                Text(appState.workouts.count < 2 ? "Import another run" : "No other workouts")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
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
    let onImport: () -> Void

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
                        .padding(.horizontal, AppDesign.Spacing.large)
                        .padding(.vertical, AppDesign.Spacing.small)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("Select a file to import and compare")
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
