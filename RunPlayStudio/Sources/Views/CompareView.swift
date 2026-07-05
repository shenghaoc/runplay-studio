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
                ComparisonEmptyView()
            }
        }
    }

    // MARK: - Selector

    private var comparisonSelector: some View {
        HStack {
            // Primary workout
            VStack(alignment: .leading) {
                Text("Primary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appState.selectedWorkout?.displayName ?? "None")
                    .font(.headline)
            }

            Spacer()

            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)

            Spacer()

            // Comparison workout
            VStack(alignment: .trailing) {
                Text("Comparison")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.availableForComparison.isEmpty {
                    Text("No other workouts")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Comparison", selection: Binding(
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
            // Winner banner
            HStack {
                Image(systemName: winnerIcon)
                    .foregroundStyle(winnerColor)
                Text(summary.winner.label)
                    .font(.headline)
                    .foregroundStyle(winnerColor)
            }

            // Metric deltas
            HStack(spacing: 24) {
                DeltaCard(label: "Distance", value: summary.distanceDeltaFormatted)
                DeltaCard(label: "Duration", value: summary.durationDeltaFormatted)
                DeltaCard(label: "Pace", value: summary.paceDeltaFormatted)
            }

            // Warnings
            if !summary.warnings.isEmpty {
                HStack {
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning.rawValue, systemImage: warning.icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Comparison Empty State

struct ComparisonEmptyView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Select a comparison workout")
                .font(.title2)

            Text("Load at least two runs to compare them")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
