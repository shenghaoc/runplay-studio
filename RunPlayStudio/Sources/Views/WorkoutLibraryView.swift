import SwiftUI
import RunPlayCore

/// All Runs workspace: searchable, filterable library table.
struct WorkoutLibraryView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: WorkoutLibraryViewModel

    @State private var workoutToDelete: RunWorkout?
    @State private var metadataEditorWorkout: RunWorkout?
    @State private var tagEditorWorkoutIDs: Set<UUID>?
    @State private var showManageTags = false
    @State private var showCreateTag = false
    @State private var showSaveCollection = false
    @State private var collectionToDelete: WorkoutSmartCollection?
    @State private var collectionDeleteError: String?
    @State private var createTagName = ""
    @State private var createTagColor: WorkoutTagColor = .default
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
        .navigationTitle(navigationTitle)
        .focusSection()
        .onReceive(viewModel.objectWillChange) { _ in
            appState.requestSessionSave()
        }
        .onExitCommand {
            if searchFocused, !viewModel.searchText.isEmpty {
                viewModel.clearSearch()
            }
        }
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
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
        .sheet(isPresented: Binding(
            get: { tagEditorWorkoutIDs != nil },
            set: { if !$0 { tagEditorWorkoutIDs = nil } }
        )) {
            tagEditorSheet
        }
        .sheet(isPresented: $showManageTags) {
            ManageTagsSheet(
                tags: appState.tags,
                assignmentCounts: assignmentCounts,
                onClose: { showManageTags = false },
                onCreate: { name, color in
                    let tag = await appState.createTag(name: name, color: color)
                    return tag != nil
                },
                onUpdate: { id, name, color in
                    let tag = await appState.updateTag(id: id, name: name, color: color)
                    return tag != nil
                },
                onDelete: { id in
                    await appState.deleteTag(id: id)
                },
                onReorder: { ids in
                    await appState.reorderTags(ids)
                },
                errorMessage: Binding(
                    get: { appState.organizationEditError },
                    set: { appState.organizationEditError = $0 }
                )
            )
        }
        .sheet(isPresented: $showCreateTag) {
            createTagSheet
        }
        .sheet(isPresented: $showSaveCollection) {
            SaveSmartCollectionSheet(
                suggestedSummary: WorkoutSmartCollectionQuerySummary.make(
                    query: viewModel.currentSavedQuery(),
                    tagsByID: viewModel.tagsByID
                ),
                onCancel: { showSaveCollection = false },
                onSave: { name in
                    Task {
                        appState.organizationEditError = nil
                        let created = await appState.createSmartCollection(
                            name: name,
                            query: viewModel.currentSavedQuery()
                        )
                        if created != nil {
                            showSaveCollection = false
                        }
                    }
                },
                errorMessage: Binding(
                    get: { appState.organizationEditError },
                    set: { appState.organizationEditError = $0 }
                )
            )
        }
        .sheet(isPresented: $appState.showSmartCollectionsManager) {
            ManageSmartCollectionsSheet(
                collections: appState.smartCollections,
                tagsByID: viewModel.tagsByID,
                onClose: { appState.showSmartCollectionsManager = false },
                onOpen: { id in
                    appState.showSmartCollection(id: id)
                },
                onRename: { id, name in
                    guard let existing = appState.smartCollections.first(where: { $0.id == id }) else {
                        return false
                    }
                    let updated = await appState.updateSmartCollection(
                        id: id,
                        name: name,
                        query: existing.query
                    )
                    return updated != nil
                },
                onDelete: { id in
                    await appState.deleteSmartCollection(id: id)
                },
                onReorder: { ids in
                    await appState.reorderSmartCollections(ids)
                },
                errorMessage: Binding(
                    get: { appState.organizationEditError },
                    set: { appState.organizationEditError = $0 }
                )
            )
        }
        .alert("Delete Smart Collection", isPresented: Binding(
            get: { collectionToDelete != nil },
            set: { if !$0 { collectionToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { collectionToDelete = nil }
            Button("Delete", role: .destructive) {
                guard let collection = collectionToDelete else { return }
                collectionToDelete = nil
                Task { @MainActor in
                    let succeeded = await appState.deleteSmartCollection(id: collection.id)
                    if !succeeded {
                        collectionDeleteError = appState.organizationEditError
                            ?? "The smart collection could not be deleted."
                    }
                }
            }
        } message: {
            if let collection = collectionToDelete {
                Text("Delete “\(collection.name)”? Workouts and tags are not affected.")
            }
        }
        .alert("Unable to Delete Smart Collection", isPresented: Binding(
            get: { collectionDeleteError != nil },
            set: { if !$0 { collectionDeleteError = nil } }
        )) {
            Button("OK") { collectionDeleteError = nil }
        } message: {
            Text(collectionDeleteError ?? "The smart collection could not be deleted.")
        }
    }

    private var navigationTitle: String {
        if let collection = viewModel.activeSmartCollection {
            return collection.name
        }
        return "All Runs"
    }

    private var assignmentCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for entry in viewModel.entries {
            for tagID in entry.tagIDs {
                counts[tagID, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppDesign.Spacing.small) {
                    Text(navigationTitle)
                        .font(.title2.weight(.semibold))
                    if viewModel.isCollectionModified {
                        Text("Modified")
                            .font(AppDesign.Typography.compactLabel.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                            .accessibilityLabel("Collection modified")
                    }
                }
                Text(resultSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(resultSummary)
            }
            Spacer()
            if case .smartCollection = viewModel.queryContext {
                collectionActions
            }
        }
        .padding(.horizontal, AppDesign.Spacing.large)
        .padding(.vertical, AppDesign.Spacing.medium)
    }

    @ViewBuilder
    private var collectionActions: some View {
        HStack(spacing: AppDesign.Spacing.small) {
            if viewModel.isCollectionModified {
                Button("Revert") {
                    viewModel.revertActiveCollection()
                }
                .help("Restore the saved collection query")
                Button("Update Collection") {
                    Task { _ = await appState.updateActiveSmartCollectionFromCurrentQuery() }
                }
                .help("Save the current search and filters to this collection")
                .keyboardShortcut(.defaultAction)
            }
            if let collection = viewModel.activeSmartCollection {
                Button("Rename…") {
                    // Lightweight rename via the manage sheet focused flow.
                    appState.showSmartCollectionsManager = true
                }
                Button("Delete…", role: .destructive) {
                    collectionToDelete = collection
                }
            }
        }
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

                if appState.canManageOrganization {
                    Menu {
                        Button("Save as Smart Collection…") {
                            appState.organizationEditError = nil
                            showSaveCollection = true
                        }
                        Button("Manage Tags…") {
                            appState.organizationEditError = nil
                            showManageTags = true
                        }
                        Button("Manage Smart Collections…") {
                            appState.organizationEditError = nil
                            appState.showSmartCollectionsManager = true
                        }
                    } label: {
                        Label("Organise", systemImage: "folder.badge.gearshape")
                    }
                    .help("Tags and smart collections")
                }
            }

            if viewModel.activeFilterCount > 0 {
                Text("\(viewModel.activeFilterCount) filter\(viewModel.activeFilterCount == 1 ? "" : "s") active")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }

            if let bulkLabel = bulkTagActionLabel {
                HStack {
                    Button(bulkLabel) {
                        tagEditorWorkoutIDs = viewModel.persistedSelectedWorkoutIDs(
                            libraryIDs: appState.libraryWorkoutIDs
                        )
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, AppDesign.Spacing.large)
        .padding(.vertical, AppDesign.Spacing.small)
    }

    private var bulkTagActionLabel: String? {
        let ids = viewModel.persistedSelectedWorkoutIDs(libraryIDs: appState.libraryWorkoutIDs)
        guard ids.count > 1 else { return nil }
        return "Edit Tags for \(ids.count) Runs…"
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
                Button("Custom Date Range…") {
                    viewModel.dateFilter = .custom(
                        start: viewModel.customDateStart,
                        end: viewModel.customDateEnd
                    )
                }
            }

            if case .custom = viewModel.dateFilter {
                DatePicker("From", selection: $viewModel.customDateStart, displayedComponents: .date)
                DatePicker("To", selection: $viewModel.customDateEnd, displayedComponents: .date)
                    .onChange(of: viewModel.customDateStart) { _, _ in
                        viewModel.dateFilter = .custom(
                            start: viewModel.customDateStart,
                            end: viewModel.customDateEnd
                        )
                    }
                    .onChange(of: viewModel.customDateEnd) { _, _ in
                        viewModel.dateFilter = .custom(
                            start: viewModel.customDateStart,
                            end: viewModel.customDateEnd
                        )
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
            tagFilterMenu

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

    @ViewBuilder
    private var tagFilterMenu: some View {
        Menu("Tags") {
            Button("Any Tags") { viewModel.tagFilter = .anyTags }
            Button("Untagged Only") { viewModel.tagFilter = .untaggedOnly }
            if !appState.tags.isEmpty {
                Divider()
                Menu("Match Any Selected") {
                    ForEach(appState.tags) { tag in
                        Button {
                            toggleSelectedTag(tag.id, match: .any)
                        } label: {
                            tagMenuLabel(tag, match: .any)
                        }
                    }
                }
                Menu("Match All Selected") {
                    ForEach(appState.tags) { tag in
                        Button {
                            toggleSelectedTag(tag.id, match: .all)
                        } label: {
                            tagMenuLabel(tag, match: .all)
                        }
                    }
                }
            }
        }
    }

    private func tagMenuLabel(_ tag: WorkoutTag, match: WorkoutLibraryTagMatchMode) -> some View {
        let selected: Bool = {
            if case .selected(let ids, let mode) = viewModel.tagFilter {
                return mode == match && ids.contains(tag.id)
            }
            return false
        }()
        return HStack {
            Text(tag.name)
            if selected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func toggleSelectedTag(_ id: UUID, match: WorkoutLibraryTagMatchMode) {
        switch viewModel.tagFilter {
        case .selected(let ids, let mode) where mode == match:
            var next = ids
            if next.contains(id) {
                next.remove(id)
            } else {
                next.insert(id)
            }
            viewModel.tagFilter = next.isEmpty ? .anyTags : .selected(tagIDs: next, match: match)
        default:
            viewModel.tagFilter = .selected(tagIDs: [id], match: match)
        }
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

            TableColumn("Tags") { entry in
                let tags = entry.tagIDs.compactMap { viewModel.tagsByID[$0] }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                WorkoutTagChipRow(tags: tags)
            }
            .width(min: 100, ideal: 160)

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
            let persisted = ids.intersection(appState.libraryWorkoutIDs)
            if ids.count == 1, let id = ids.first,
               let entry = viewModel.entry(for: id),
               let workout = appState.workouts.first(where: { $0.id == id }) {
                Button("Open") { appState.openWorkoutFromLibrary(workout) }
                Divider()
                if appState.canFavorite(workout) {
                    Button(entry.isFavorite ? "Unfavourite" : "Favourite") {
                        Task { await appState.setFavorite(!entry.isFavorite, workoutID: id) }
                    }
                } else {
                    Button("Favourite") {}
                        .disabled(true)
                        .help("Favourites apply to imported library workouts, not bundled demos.")
                }
                if appState.canEditLibraryMetadata(workout) {
                    Button("Edit Details…") {
                        appState.metadataEditError = nil
                        metadataEditorWorkout = workout
                    }
                } else {
                    Button("Edit Details…") {}
                        .disabled(true)
                        .help("Details can only be edited for imported library workouts.")
                }
                if appState.canTag(workout) {
                    Button("Edit Tags…") {
                        appState.organizationEditError = nil
                        tagEditorWorkoutIDs = [id]
                    }
                } else {
                    Button("Edit Tags…") {}
                        .disabled(true)
                        .help("Tags apply to imported library workouts, not bundled demos.")
                }
                Divider()
                Button("Delete", role: .destructive) {
                    workoutToDelete = workout
                }
            } else if persisted.count > 1 {
                Button("Edit Tags for \(persisted.count) Runs…") {
                    appState.organizationEditError = nil
                    tagEditorWorkoutIDs = persisted
                }
            }
        } primaryAction: { ids in
            // Double-click opens the clicked workout even if multi-selected.
            if let id = ids.first,
               let workout = appState.workouts.first(where: { $0.id == id }) {
                appState.openWorkoutFromLibrary(workout)
            }
        }
        .onDeleteCommand {
            // Delete only when exactly one row is selected.
            guard viewModel.tableSelection.count == 1,
                  let id = viewModel.tableSelection.first,
                  let workout = appState.workouts.first(where: { $0.id == id }) else {
                return
            }
            workoutToDelete = workout
        }
        .onKeyPress(.return) {
            // Return opens only when exactly one workout is selected.
            guard viewModel.tableSelection.count == 1,
                  let id = viewModel.tableSelection.first,
                  let workout = appState.workouts.first(where: { $0.id == id }) else {
                return .ignored
            }
            appState.openWorkoutFromLibrary(workout)
            return .handled
        }
        .focusable()
        .padding(.horizontal, AppDesign.Spacing.small)
    }

    // MARK: - Tag editor sheets

    @ViewBuilder
    private var tagEditorSheet: some View {
        if let ids = tagEditorWorkoutIDs {
            if ids.count == 1, let id = ids.first {
                WorkoutTagEditorSheet(
                    availableTags: appState.tags,
                    initialSelected: viewModel.entry(for: id)?.tagIDs ?? [],
                    title: "Edit Tags",
                    onCancel: { tagEditorWorkoutIDs = nil },
                    onSave: { selected in
                        Task {
                            let ok = await appState.setTags(selected, forWorkoutID: id)
                            if ok { tagEditorWorkoutIDs = nil }
                        }
                    },
                    onCreateTag: {
                        // Dismiss the tag editor before presenting the create
                        // sheet; SwiftUI cannot reliably stack both sheets
                        // from the same parent presentation transaction.
                        tagEditorWorkoutIDs = nil
                        Task { @MainActor in
                            await Task.yield()
                            showCreateTag = true
                        }
                    },
                    onManageTags: {
                        tagEditorWorkoutIDs = nil
                        showManageTags = true
                    },
                    errorMessage: Binding(
                        get: { appState.organizationEditError },
                        set: { appState.organizationEditError = $0 }
                    )
                )
            } else {
                let states = bulkStates(for: ids)
                BulkWorkoutTagEditorSheet(
                    availableTags: appState.tags,
                    workoutCount: ids.count,
                    initialStates: states,
                    onCancel: { tagEditorWorkoutIDs = nil },
                    onSave: { add, remove in
                        Task {
                            let ok = await appState.updateTags(
                                workoutIDs: ids,
                                addTagIDs: add,
                                removeTagIDs: remove
                            )
                            if ok { tagEditorWorkoutIDs = nil }
                        }
                    },
                    errorMessage: Binding(
                        get: { appState.organizationEditError },
                        set: { appState.organizationEditError = $0 }
                    )
                )
            }
        }
    }

    private func bulkStates(for workoutIDs: Set<UUID>) -> [UUID: BulkTagState] {
        var result: [UUID: BulkTagState] = [:]
        for tag in appState.tags {
            var applied = 0
            for id in workoutIDs {
                if viewModel.entry(for: id)?.tagIDs.contains(tag.id) == true {
                    applied += 1
                }
            }
            if applied == 0 {
                result[tag.id] = .noneApplied
            } else if applied == workoutIDs.count {
                result[tag.id] = .allApplied
            } else {
                result[tag.id] = .mixed
            }
        }
        return result
    }

    private var createTagSheet: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Create Tag")
                .font(.title2.weight(.semibold))
            TextField("Tag name", text: $createTagName)
                .textFieldStyle(.roundedBorder)
            Picker("Color", selection: $createTagColor) {
                ForEach(WorkoutTagColor.allCases, id: \.self) { color in
                    Text(color.displayName).tag(color)
                }
            }
            if let error = appState.organizationEditError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showCreateTag = false
                    createTagName = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        let tag = await appState.createTag(name: createTagName, color: createTagColor)
                        if tag != nil {
                            createTagName = ""
                            createTagColor = .default
                            showCreateTag = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 360)
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
