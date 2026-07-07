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
            Section("Runs") {
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
            }
        }
        .listStyle(.sidebar)
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
                Text("Are you sure you want to delete \"\(workout.displayName)\"? This cannot be undone.")
            }
        }
    }
}

// MARK: - Workout Row

struct WorkoutRow: View {
    let workout: RunWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workout.displayName)
                .font(.headline)
                .lineLimit(1)

            HStack(spacing: 12) {
                Label(workout.summary.formattedDistance, systemImage: "figure.run")
                Label(workout.summary.formattedDuration, systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let avgHR = workout.summary.averageHeartRateBPM, avgHR.isFinite, avgHR > 0 {
                Label(
                    String(format: "%.0f bpm avg", avgHR),
                    systemImage: "heart.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
