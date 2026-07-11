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
        .onDeleteCommand {
            if let selectedWorkout {
                workoutToDelete = selectedWorkout
            }
        }
        .navigationTitle("RunPlay Studio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onImport) {
                    Label("Import", systemImage: "plus")
                }
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
            // Left accent bar colored by HR zone
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text(workout.displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: AppDesign.Spacing.large) {
                    metricPill(icon: "figure.run", value: workout.summary.formattedDistance)
                    metricPill(icon: "clock", value: workout.summary.formattedDuration)
                }

                if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite, avgHR > 0 {
                    HStack(spacing: AppDesign.Spacing.xxSmall) {
                        Image(systemName: "heart.fill")
                            .font(AppDesign.Typography.compactIcon)
                        Text(String(format: "%.0f bpm avg", avgHR))
                            .font(AppDesign.Typography.compactLabel)
                    }
                    .foregroundStyle(AppDesign.MetricColor.heartRate)
                }
            }
        }
        .padding(.vertical, AppDesign.Spacing.xSmall)
    }

    private func metricPill(icon: String, value: String) -> some View {
        HStack(spacing: AppDesign.Spacing.xxSmall) {
            Image(systemName: icon)
                .font(AppDesign.Typography.compactIcon)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var accentColor: Color {
        if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite, avgHR > 0 {
            return AppDesign.MetricColor.heartRate.opacity(0.6)
        }
        return AppDesign.MetricColor.distance.opacity(0.4)
    }
}
