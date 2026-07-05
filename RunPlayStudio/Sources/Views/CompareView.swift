import SwiftUI

/// Main comparison view showing two workouts side by side.
struct CompareView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Workout selector
            comparisonSelector

            if let pair = appState.comparisonPair {
                Divider()

                // Summary deltas
                if let summary = appState.comparisonSummary {
                    ComparisonSummaryView(summary: summary)
                        .padding()
                        .background(.ultraThinMaterial)

                    Divider()
                }

                // Main content: map + splits
                HStack(spacing: 0) {
                    // Route overlay map
                    ComparisonMapView(
                        primaryPoints: pair.primary.routePoints,
                        comparisonPoints: pair.comparison.routePoints
                    )
                    .frame(minWidth: 400)

                    Divider()

                    // Split comparison table
                    SplitComparisonTableView(splits: appState.splitComparisons)
                        .frame(minWidth: 300)
                }

                Divider()

                // Pace comparison chart
                ComparisonChartView(metrics: appState.comparisonMetrics)
                    .frame(height: 200)
                    .padding()
            } else {
                ComparisonEmptyView(
                    workoutCount: appState.workouts.count,
                    primaryName: appState.selectedWorkout?.displayName
                )
            }
        }
    }

    // MARK: - Selector

    private var comparisonSelector: some View {
        HStack {
            // Primary workout
            VStack(alignment: .leading, spacing: 4) {
                Text("Primary Run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appState.selectedWorkout?.displayName ?? "None")
                    .font(.headline)
                    .lineLimit(1)
                Text("Current selection")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)

            Spacer()

            // Comparison workout
            VStack(alignment: .trailing, spacing: 4) {
                Text("Compare Against")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.availableForComparison.isEmpty {
                    Text(appState.workouts.count < 2 ? "Import another run" : "No other workouts")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Compare Against", selection: Binding(
                        get: { appState.comparisonWorkout },
                        set: { appState.setComparison($0) }
                    )) {
                        Text("Select workout").tag(nil as RunWorkout?)
                        ForEach(appState.availableForComparison) { workout in
                            Text(workout.displayName).tag(workout as RunWorkout?)
                        }
                    }
                    .frame(maxWidth: 200)
                }

                if let message = appState.comparisonSelectionMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if appState.isComparing {
                Button("Clear") {
                    appState.clearComparison()
                }
                .font(.caption)
            }
        }
        .padding()
    }
}

// MARK: - Comparison Summary

struct ComparisonSummaryView: View {
    let summary: WorkoutComparisonSummary

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: winnerIcon)
                        .foregroundStyle(winnerColor)
                    Text(summary.winner.label)
                        .font(.headline)
                        .foregroundStyle(winnerColor)
                }

                Text("\(summary.primaryTitle) vs \(summary.comparisonTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Metric deltas
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                DeltaCard(label: "Distance", value: summary.distanceDeltaFormatted)
                DeltaCard(label: "Duration", value: summary.durationDeltaFormatted)
                DeltaCard(label: "Pace", value: summary.paceDeltaFormatted)
                DeltaCard(label: "Elevation", value: summary.elevationGainDeltaFormatted)
                if let avgHR = summary.avgHRDeltaFormatted {
                    DeltaCard(label: "Avg HR", value: avgHR)
                }
                if let maxHR = summary.maxHRDeltaFormatted {
                    DeltaCard(label: "Max HR", value: maxHR)
                }
            }

            // Warnings
            if !summary.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning.rawValue, systemImage: warning.icon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        case .primary: return .green
        case .comparison: return .red
        case .tie: return .secondary
        case .unavailable: return .secondary
        }
    }
}

struct DeltaCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Comparison Empty State

struct ComparisonEmptyView: View {
    let workoutCount: Int
    let primaryName: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2)

            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if workoutCount < 2 { return "Import another run" }
        if primaryName == nil { return "Select a primary run" }
        return "Select a comparison run"
    }

    private var message: String {
        if workoutCount == 0 { return "No runs loaded yet" }
        if workoutCount == 1 { return "Only one run is loaded" }
        if let primaryName { return "Primary: \(primaryName)" }
        return "Choose a run in the sidebar"
    }
}
