import SwiftUI
import RunPlayCore

/// Sidebar showing list of loaded workouts with import button.
struct SidebarView: View {
    let workouts: [RunWorkout]
    @Binding var selectedWorkout: RunWorkout?
    var onImport: () -> Void
    var onDelete: ((RunWorkout) -> Void)?

    @State private var workoutToDelete: RunWorkout?

    var body: some View {
        List(selection: $selectedWorkout) {
            Section {
                ForEach(workouts) { workout in
                    WorkoutRow(workout: workout)
                        .tag(workout)
                        .contextMenu {
                            Button(role: .destructive) {
                                workoutToDelete = workout
                            } label: {
                                Label("Delete Run", systemImage: "trash")
                            }
                        }
                }
                .onDelete { indexSet in
                    if let index = indexSet.first {
                        workoutToDelete = workouts[index]
                    }
                }
            } header: {
                Text("Runs")
                    .font(AppDesign.Typography.compactLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
#if os(macOS)
        .onDeleteCommand {
            if let selectedWorkout {
                workoutToDelete = selectedWorkout
            }
        }
#endif
        .navigationTitle("RunPlay Studio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) {
                    Label("Import", systemImage: "plus")
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Import a workout file (⌘I)")
            }
        }
        .alert("Delete Run", isPresented: Binding(
            get: { workoutToDelete != nil },
            set: { if !$0 { workoutToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { workoutToDelete = nil }
            Button("Delete", role: .destructive) {
                if let workout = workoutToDelete {
                    onDelete?(workout)
                }
                workoutToDelete = nil
            }
        } message: {
            if let workout = workoutToDelete {
                Text("Delete RunPlay Studio’s stored copy of \"\(workout.displayName)\"? The original imported file will not be changed.")
            }
        }
    }
}

// MARK: - Workout Row

struct WorkoutRow: View {
    let workout: RunWorkout

    var body: some View {
        HStack(spacing: AppDesign.Spacing.medium) {
            Image(systemName: "figure.run.circle.fill")
                .font(.title3)
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text(workout.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: AppDesign.Spacing.small) {
                    metricPill(icon: "figure.run", value: workout.summary.formattedDistance)
                    metadataSeparator
                    metricPill(icon: "clock", value: workout.summary.formattedDuration)

                    if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite, avgHR > 0 {
                        metadataSeparator
                        metricPill(
                            icon: "heart.fill",
                            value: String(format: "%.0f bpm", avgHR),
                            color: AppDesign.MetricColor.heartRate
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppDesign.Spacing.xSmall)
        .help(workout.displayName)
    }

    private func metricPill(icon: String, value: String, color: Color = .secondary) -> some View {
        HStack(spacing: AppDesign.Spacing.xxSmall) {
            Image(systemName: icon)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(color.opacity(0.8))
            Text(value)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private var metadataSeparator: some View {
        Text("·")
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.quaternary)
            .accessibilityHidden(true)
    }

    private var accentColor: Color {
        if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite, avgHR > 0 {
            return AppDesign.MetricColor.heartRate.opacity(0.6)
        }
        return AppDesign.MetricColor.distance.opacity(0.4)
    }
}
