import SwiftUI
import RunPlayCore

/// Sidebar showing list of loaded workouts with import button.
struct SidebarView: View {
    let workouts: [RunWorkout]
    @Binding var selectedWorkout: RunWorkout?
    var onImport: () -> Void

    var body: some View {
        List(selection: $selectedWorkout) {
            Section("Runs") {
                ForEach(workouts) { workout in
                    WorkoutRow(workout: workout)
                        .tag(workout)
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

            if workout.hasHeartRateData {
                Label(
                    "\(Int(workout.summary.averageHeartRateBPM ?? 0)) bpm avg",
                    systemImage: "heart.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
