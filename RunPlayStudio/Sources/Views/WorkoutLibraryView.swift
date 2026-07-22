import SwiftUI
import RunPlayCore

/// All Runs workspace: searchable, filterable library table.
struct WorkoutLibraryView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: WorkoutLibraryViewModel

    @State private var workoutToDelete: RunWorkout?
    @State private var metadataEditorWorkout: RunWorkout?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("All Runs")
        .onExitCommand {
            if searchFocused, !viewModel.searchText.isEmpty {
                viewModel.clearSearch()
            }
        }
        .alert("Delete Run", isPresented: Binding(
            get: { workoutToDelete != nil },
            set: { if !$0 { workoutToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { workoutToDelete = nil }
            Button("Delete", role: .destructive) {
                if let workout = workoutToDelete {
                    Task { await appState.deleteWorkout(workout) }
                }
                workoutToDelete = nil
            }
        } message: {
            if let workout = workoutToDelete {
                Text("Delete RunPlay Studio’s stored copy of \"\(workout.displayName)\"? The original imported file will not be changed.")
            }
        }
        .sheet(item: $metadataEditorWorkout) { workout in
            WorkoutMetadataEditorSheet(
                workout: workout,
                onCancel: { metadataEditorWorkout = nil },
                onSave: { name, notes in
                    Task {
                        let ok = await appState.updateWorkoutMetadata(
                            workoutID: workout.id,
                            name: name,
                            notes: notes
                        )
                        if ok {
                            metadataEditorWorkout = nil
                        }
                    }
                },
                errorMessage: Binding(
                    get: { appState.metadataEditError },
                    set: { appState.metadataEditError = $0 }
                )
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("All Runs")
                    .font(.title2.weight(.semibold))
                Text(resultSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(resultSummary)
            }
            Spacer()
        }
        .padding(.horizontal, AppDesign.Spacing.large)
        .padding(.vertical, AppDesign.Spacing.medium)
    }

    private var resultSummary: String {
        if viewModel.totalCount == 0 {
            return "No runs in your library"
        }
        if viewModel.filteredCount == viewModel.totalCount {
            return "\(viewModel.totalCount) run\(viewModel.totalCount == 1 ? "" : "s")"
        }
        return "\(viewModel.filteredCount) of \(viewModel.totalCount) runs"
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack(spacing: AppDesign.Spacing.medium) {
                TextField("Search runs", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("Search runs")
                    .frame(maxWidth: 360)
                    .onSubmit { /* keep focus; filtering is live */ }

                Menu {
                    Picker("Sort", selection: $viewModel.sort) {
                        ForEach(WorkoutLibrarySort.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort library results")

                filterMenu

                if viewModel.hasActiveSearchOrFilters {
                    Button("Clear") {
                        viewModel.clearSearchAndFilters()
                    }
                    .help("Clear search and filters")
                }

                Spacer()
            }

            if viewModel.activeFilterCount > 0 {
                Text("\(viewModel.activeFilterCount) filter\(viewModel.activeFilterCount == 1 ? "" : "s") active")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppDesign.Spacing.large)
        .padding(.vertical, AppDesign.Spacing.small)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Favourites", selection: $viewModel.favoriteFilter) {
                ForEach(WorkoutLibraryFavoriteFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Picker("Source", selection: $viewModel.sourceFilter) {
                ForEach(WorkoutLibrarySourceFilter.allCases, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }

            Menu("Date") {
                Button("All Time") { viewModel.dateFilter = .allTime }
                Button("Last 30 Days") { viewModel.dateFilter = .last30Days }
                Button("Last 90 Days") { viewModel.dateFilter = .last90Days }
                Button("Current Calendar Year") { viewModel.dateFilter = .currentCalendarYear }
                Button("Custom Date Range…") { viewModel.dateFilter = .custom(start: viewModel.customDateStart, end: viewModel.customDateEnd) }
            }

            if case .custom = viewModel.dateFilter {
                DatePicker("From", selection: $viewModel.customDateStart, displayedComponents: .date)
                DatePicker("To", selection: $viewModel.customDateEnd, displayedComponents: .date)
                    .onChange(of: viewModel.customDateStart) { _, _ in
                        viewModel.dateFilter = .custom(start: viewModel.customDateStart, end: viewModel.customDateEnd)
                    }
                    .onChange(of: viewModel.customDateEnd) { _, _ in
                        viewModel.dateFilter = .custom(start: viewModel.customDateStart, end: viewModel.customDateEnd)
                    }
            }

            Divider()

            Toggle(
                "Has Heart Rate",
                isOn: Binding(
                    get: { viewModel.dataFilters.requiresHeartRate },
                    set: { value in
                        var filters = viewModel.dataFilters
                        filters.requiresHeartRate = value
                        viewModel.dataFilters = filters
                    }
                )
            )
            Toggle(
                "Has Corrected Elevation",
                isOn: Binding(
                    get: { viewModel.dataFilters.requiresCorrectedElevation },
                    set: { value in
                        var filters = viewModel.dataFilters
                        filters.requiresCorrectedElevation = value
                        viewModel.dataFilters = filters
                    }
                )
            )
            Toggle(
                "Has Recorded Laps",
                isOn: Binding(
                    get: { viewModel.dataFilters.requiresRecordedLaps },
                    set: { value in
                        var filters = viewModel.dataFilters
                        filters.requiresRecordedLaps = value
                        viewModel.dataFilters = filters
                    }
                )
            )

            Divider()
            Button("Clear Filters") { viewModel.clearFilters() }
        } label: {
            Label(
                viewModel.activeFilterCount > 0
                    ? "Filters (\(viewModel.activeFilterCount))"
                    : "Filters",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .help("Filter the library")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle:
            ProgressView("Loading library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading library")
        case .loading:
            if viewModel.resultIDs.isEmpty {
                ProgressView("Loading library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading library")
            } else {
                libraryTable
            }
        case .emptyLibrary:
            emptyLibraryState
        case .emptySearch(let query):
            emptySearchState(query: query)
        case .emptyFilters:
            emptyFiltersState
        case .failed(let message):
            VStack(spacing: AppDesign.Spacing.medium) {
                Text("Could not update results")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { viewModel.retryQuery() }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .ready:
            libraryTable
        }
    }

    private var emptyLibraryState: some View {
        VStack(spacing: AppDesign.Spacing.medium) {
            Image(systemName: "figure.run")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No runs yet")
                .font(.title3.weight(.semibold))
            Text("Import a GPX, TCX, FIT, or JSON file, or a Strava archive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Import File…") { appState.showImporter = true }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Import Strava Archive…") { appState.showArchiveImporter = true }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptySearchState(query: String) -> some View {
        VStack(spacing: AppDesign.Spacing.medium) {
            Text("No runs match “\(query)”")
                .font(.title3.weight(.semibold))
            Button("Clear Search") { viewModel.clearSearch() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyFiltersState: some View {
        VStack(spacing: AppDesign.Spacing.medium) {
            Text("No runs match the selected filters.")
                .font(.title3.weight(.semibold))
            Button("Clear Filters") { viewModel.clearFilters() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var libraryTable: some View {
        Table(viewModel.matchingEntries, selection: $viewModel.tableSelection) {
            TableColumn("") { entry in
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(entry.isFavorite ? Color.yellow : Color.secondary)
                    .accessibilityLabel(entry.isFavorite ? "Favourite" : "Not a favourite")
            }
            .width(24)

            TableColumn("Date") { entry in
                Text(Self.formatDate(entry.startDate))
                    .font(.body.monospacedDigit())
                    .accessibilityLabel(Self.formatDate(entry.startDate))
            }
            .width(min: 100, ideal: 130)

            TableColumn("Name") { entry in
                Text(entry.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.notes ?? entry.displayName)
                    .accessibilityLabel(entry.displayName)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Distance") { entry in
                Text(Self.formatDistance(entry.totalDistanceMeters))
                    .font(.body.monospacedDigit())
            }
            .width(min: 80, ideal: 90)

            TableColumn("Active Pace") { entry in
                Text(Self.formatPace(entry.activePaceSecondsPerKilometer))
                    .font(.body.monospacedDigit())
            }
            .width(min: 90, ideal: 100)

            TableColumn("Elapsed") { entry in
                Text(Self.formatElapsed(entry.totalElapsedSeconds))
                    .font(.body.monospacedDigit())
            }
            .width(min: 70, ideal: 80)

            TableColumn("Source") { entry in
                Text(entry.source.displayName)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Device") { entry in
                Text(entry.deviceName ?? "—")
                    .lineLimit(1)
                    .foregroundStyle(entry.deviceName == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let entry = viewModel.entry(for: id),
               let workout = appState.workouts.first(where: { $0.id == id }) {
                Button("Open") { appState.openWorkoutFromLibrary(workout) }
                Divider()
                if appState.canFavorite(workout) {
                    Button(entry.isFavorite ? "Unfavourite" : "Favourite") {
                        Task { await appState.setFavorite(!entry.isFavorite, workoutID: id) }
                    }
                }
                Button("Edit Details…") {
                    appState.metadataEditError = nil
                    metadataEditorWorkout = workout
                }
                Divider()
                Button("Delete", role: .destructive) {
                    workoutToDelete = workout
                }
            }
        } primaryAction: { ids in
            if let id = ids.first,
               let workout = appState.workouts.first(where: { $0.id == id }) {
                appState.openWorkoutFromLibrary(workout)
            }
        }
        .onDeleteCommand {
            if let id = viewModel.tableSelection,
               let workout = appState.workouts.first(where: { $0.id == id }) {
                workoutToDelete = workout
            }
        }
        .onKeyPress(.return) {
            if let id = viewModel.tableSelection,
               let workout = appState.workouts.first(where: { $0.id == id }) {
                appState.openWorkoutFromLibrary(workout)
                return .handled
            }
            return .ignored
        }
        .focusable()
        .padding(.horizontal, AppDesign.Spacing.small)
    }

    // MARK: - Formatting

    private static let missing = "—"

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return missing }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func formatDistance(_ meters: Double) -> String {
        guard meters.isFinite, meters > 0 else { return missing }
        return DisplayFormatter.formatDistance(meters)
    }

    private static func formatPace(_ secondsPerKm: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0 else { return missing }
        return DisplayFormatter.formatPace(secondsPerKm)
    }

    private static func formatElapsed(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return missing }
        return DisplayFormatter.formatDuration(seconds)
    }
}

// MARK: - Metadata editor

struct WorkoutMetadataEditorSheet: View {
    let workout: RunWorkout
    let onCancel: () -> Void
    let onSave: (String?, String?) -> Void
    @Binding var errorMessage: String?

    @State private var name: String
    @State private var notes: String
    @FocusState private var focusedField: Field?

    private enum Field { case name, notes }

    private let policy = WorkoutMetadataEditingPolicy.default

    init(
        workout: RunWorkout,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String?, String?) -> Void,
        errorMessage: Binding<String?>
    ) {
        self.workout = workout
        self.onCancel = onCancel
        self.onSave = onSave
        self._errorMessage = errorMessage
        _name = State(initialValue: workout.metadata.name ?? "")
        _notes = State(initialValue: workout.metadata.notes ?? "")
    }

    private var isChanged: Bool {
        let originalName = workout.metadata.name ?? ""
        let originalNotes = workout.metadata.notes ?? ""
        return name != originalName || notes != originalNotes
    }

    private var validationError: String? {
        do {
            _ = try policy.normalize(name: name, notes: notes)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canSave: Bool {
        isChanged && validationError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Edit Details")
                .font(.title2.weight(.semibold))

            Text("Name")
                .font(.headline)
            TextField("Workout name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .accessibilityLabel("Workout name")
            Text("Up to \(policy.maxNameScalars) characters. Leave empty for automatic naming.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Notes")
                .font(.headline)
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.3))
                .focused($focusedField, equals: .notes)
                .accessibilityLabel("Workout notes")
            Text("Up to \(policy.maxNotesScalars) characters.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validationError {
                Text(validationError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(name, notes)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { focusedField = .name }
    }
}

