import SwiftUI
import RunPlayCore

/// Unified sidebar selection so Library destinations and workouts share one
/// native `List` selection binding (keyboard navigation, focus ring, VoiceOver).
enum SidebarSelection: Hashable {
    case allRuns
    case personalHeatmap
    case smartCollection(UUID)
    case workout(UUID)
}

/// Sidebar showing library destinations and bounded workout sections.
struct SidebarView: View {
    let workouts: [RunWorkout]
    let favoriteIDs: Set<UUID>
    let smartCollections: [WorkoutSmartCollection]
    let libraryCount: Int
    let totalFavoriteCount: Int
    @Binding var selection: SidebarSelection?
    var onImport: () -> Void
    var onArchiveImport: (() -> Void)? = nil
    var onDelete: ((RunWorkout) -> Void)?
    var onShowAllFavorites: (() -> Void)? = nil
    var onManageSmartCollections: (() -> Void)? = nil

    @State private var workoutToDelete: RunWorkout?

    private var sections: (
        favorites: [RunWorkout],
        recent: [RunWorkout],
        selectedOverflow: RunWorkout?
    ) {
        let selectedID: UUID? = {
            if case .workout(let id) = selection { return id }
            return nil
        }()
        return WorkoutLibrarySidebarPolicy.sidebarSections(
            workouts: workouts,
            favoriteIDs: favoriteIDs,
            selectedWorkoutID: selectedID
        )
    }

    private var visibleCollections: [WorkoutSmartCollection] {
        Array(smartCollections.prefix(WorkoutLibrarySidebarPolicy.smartCollectionCap))
    }

    private var hasMoreCollections: Bool {
        smartCollections.count > WorkoutLibrarySidebarPolicy.smartCollectionCap
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label {
                    HStack {
                        Text("All Runs")
                        Spacer()
                        if libraryCount > 0 {
                            Text("\(libraryCount)")
                                .font(AppDesign.Typography.compactLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "list.bullet")
                }
                .tag(SidebarSelection.allRuns)
                .help("Browse, search, and organise your full local library")
                .accessibilityLabel("All Runs, \(libraryCount) runs")

                Label("Personal Heatmap", systemImage: "square.grid.3x3.fill")
                    .tag(SidebarSelection.personalHeatmap)
                    .help("Show where you run most often across your local library (⌘⇧H)")
                    .accessibilityLabel("Personal Heatmap")
                    .accessibilityHint("Shows a density map of places you have run across your workout library")
            } header: {
                Text("Library")
                    .font(AppDesign.Typography.compactLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
            }

            if !smartCollections.isEmpty {
                Section {
                    ForEach(visibleCollections) { collection in
                        Label(collection.name, systemImage: "rectangle.stack")
                            .tag(SidebarSelection.smartCollection(collection.id))
                            .help("Open smart collection “\(collection.name)”")
                            .accessibilityLabel("Smart collection \(collection.name)")
                    }
                    if hasMoreCollections {
                        Button {
                            onManageSmartCollections?()
                        } label: {
                            Label("All Smart Collections…", systemImage: "rectangle.stack.badge.person.crop")
                        }
                        .accessibilityLabel("Show all smart collections")
                    }
                } header: {
                    Text("Smart Collections")
                        .font(AppDesign.Typography.compactLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                }
            }

            let bounded = sections

            if !bounded.favorites.isEmpty {
                Section {
                    ForEach(bounded.favorites) { workout in
                        WorkoutRow(workout: workout, showsFavorite: true)
                            .tag(SidebarSelection.workout(workout.id))
                            .contextMenu {
                                Button(role: .destructive) {
                                    workoutToDelete = workout
                                } label: {
                                    Label("Delete Run", systemImage: "trash")
                                }
                            }
                    }
                    if WorkoutLibrarySidebarPolicy.hasMoreFavorites(favoriteCount: totalFavoriteCount) {
                        Button {
                            onShowAllFavorites?()
                        } label: {
                            Label("All Favourites…", systemImage: "star")
                        }
                        .accessibilityLabel("Show all favourites in All Runs")
                    }
                } header: {
                    Text("Favourites")
                        .font(AppDesign.Typography.compactLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                }
            }

            if !bounded.recent.isEmpty {
                Section {
                    ForEach(bounded.recent) { workout in
                        WorkoutRow(workout: workout)
                            .tag(SidebarSelection.workout(workout.id))
                            .contextMenu {
                                Button(role: .destructive) {
                                    workoutToDelete = workout
                                } label: {
                                    Label("Delete Run", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Recent")
                        .font(AppDesign.Typography.compactLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                }
            }

            if let selected = bounded.selectedOverflow {
                Section {
                    WorkoutRow(workout: selected)
                        .tag(SidebarSelection.workout(selected.id))
                        .contextMenu {
                            Button(role: .destructive) {
                                workoutToDelete = selected
                            } label: {
                                Label("Delete Run", systemImage: "trash")
                            }
                        }
                } header: {
                    Text("Selected Run")
                        .font(AppDesign.Typography.compactLabel)
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        .onDeleteCommand {
            if case .workout(let id) = selection,
               let workout = workouts.first(where: { $0.id == id }) {
                workoutToDelete = workout
            }
        }
        .navigationTitle("RunPlay Studio")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: onImport) {
                        Label("Import File…", systemImage: "doc.badge.plus")
                    }
                    .keyboardShortcut("i", modifiers: .command)
                    if let onArchiveImport {
                        Button(action: onArchiveImport) {
                            Label("Import Strava Archive…", systemImage: "archivebox")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .shift])
                    }
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .help("Import a workout file or Strava archive")
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
    var showsFavorite: Bool = false

    var body: some View {
        HStack(spacing: AppDesign.Spacing.medium) {
            Image(systemName: showsFavorite ? "star.fill" : "figure.run.circle.fill")
                .font(.title3)
                .foregroundStyle(showsFavorite ? Color.yellow.opacity(0.9) : accentColor)
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
                    metricPill(icon: "clock", value: workout.summary.formattedElapsed)
                        .help("Elapsed time, including pauses and recording gaps.")
                        .accessibilityLabel("Elapsed \(workout.summary.formattedElapsed)")

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
