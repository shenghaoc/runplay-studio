import SwiftUI
import RunPlayCore

// MARK: - Color mapping

extension WorkoutTagColor {
    /// Reviewed light/dark presentation colors (supplemental to the tag name).
    var swiftUIColor: Color {
        switch self {
        case .blue: return Color(nsColor: .systemBlue)
        case .cyan: return Color(nsColor: .systemTeal)
        case .green: return Color(nsColor: .systemGreen)
        case .yellow: return Color(nsColor: .systemYellow)
        case .orange: return Color(nsColor: .systemOrange)
        case .red: return Color(nsColor: .systemRed)
        case .purple: return Color(nsColor: .systemPurple)
        case .gray: return Color(nsColor: .systemGray)
        }
    }

    var displayName: String {
        rawValue.capitalized
    }
}

// MARK: - Chip

/// Compact native tag chip: visible name + supplemental color.
struct WorkoutTagChip: View {
    let name: String
    let color: WorkoutTagColor
    var isCompact: Bool = true

    var body: some View {
        Text(name)
            .font(isCompact ? AppDesign.Typography.compactLabel : .caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, isCompact ? 6 : 8)
            .padding(.vertical, isCompact ? 2 : 3)
            .background(color.swiftUIColor.opacity(0.22), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(color.swiftUIColor.opacity(0.55), lineWidth: 1)
            )
            .foregroundStyle(.primary)
            .accessibilityLabel("Tag \(name)")
            .help(name)
    }
}

/// Bounded chip row for table cells and summaries.
struct WorkoutTagChipRow: View {
    let tags: [WorkoutTag]
    var limit: Int = WorkoutLibraryEntry.visibleTagChipLimit

    var body: some View {
        if tags.isEmpty {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("No tags")
        } else {
            HStack(spacing: 4) {
                ForEach(tags.prefix(limit)) { tag in
                    WorkoutTagChip(name: tag.name, color: tag.color)
                }
                if tags.count > limit {
                    Text("+\(tags.count - limit)")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(tags.count - limit) more tags")
                }
            }
            .help(tags.map(\.name).joined(separator: ", "))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tags.map(\.name).joined(separator: ", "))
        }
    }
}

// MARK: - Single tag editor

struct WorkoutTagEditorSheet: View {
    let availableTags: [WorkoutTag]
    let initialSelected: Set<UUID>
    let title: String
    let onCancel: () -> Void
    let onSave: (Set<UUID>) -> Void
    let onCreateTag: () -> Void
    let onManageTags: () -> Void
    @Binding var errorMessage: String?

    @State private var selected: Set<UUID>
    @State private var search = ""

    init(
        availableTags: [WorkoutTag],
        initialSelected: Set<UUID>,
        title: String = "Edit Tags",
        onCancel: @escaping () -> Void,
        onSave: @escaping (Set<UUID>) -> Void,
        onCreateTag: @escaping () -> Void,
        onManageTags: @escaping () -> Void,
        errorMessage: Binding<String?>
    ) {
        self.availableTags = availableTags
        self.initialSelected = initialSelected
        self.title = title
        self.onCancel = onCancel
        self.onSave = onSave
        self.onCreateTag = onCreateTag
        self.onManageTags = onManageTags
        self._errorMessage = errorMessage
        _selected = State(initialValue: initialSelected)
    }

    private var filteredTags: [WorkoutTag] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return availableTags }
        let folded = WorkoutOrganizationNameFolding.fold(trimmed)
        return availableTags.filter {
            WorkoutOrganizationNameFolding.fold($0.name).contains(folded)
        }
    }

    private var isChanged: Bool {
        selected != initialSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text(title)
                .font(.title2.weight(.semibold))

            TextField("Search tags", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search tags")

            List {
                ForEach(filteredTags) { tag in
                    Toggle(isOn: Binding(
                        get: { selected.contains(tag.id) },
                        set: { on in
                            if on { selected.insert(tag.id) } else { selected.remove(tag.id) }
                        }
                    )) {
                        HStack {
                            WorkoutTagChip(name: tag.name, color: tag.color, isCompact: false)
                            Spacer()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel("\(tag.name) tag")
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Create Tag…", action: onCreateTag)
                Button("Manage Tags…", action: onManageTags)
                Spacer()
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
                Button("Save") { onSave(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isChanged)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 420, minHeight: 420)
    }
}

// MARK: - Bulk tag editor (tri-state)

enum BulkTagState: Equatable {
    case allApplied
    case noneApplied
    case mixed
}

struct BulkWorkoutTagEditorSheet: View {
    let availableTags: [WorkoutTag]
    let workoutCount: Int
    /// Initial state per tag ID.
    let initialStates: [UUID: BulkTagState]
    let onCancel: () -> Void
    /// Final intended states after editing (all / none only; mixed means leave unchanged).
    let onSave: (_ add: Set<UUID>, _ remove: Set<UUID>) -> Void
    @Binding var errorMessage: String?

    @State private var states: [UUID: BulkTagState]

    init(
        availableTags: [WorkoutTag],
        workoutCount: Int,
        initialStates: [UUID: BulkTagState],
        onCancel: @escaping () -> Void,
        onSave: @escaping (_ add: Set<UUID>, _ remove: Set<UUID>) -> Void,
        errorMessage: Binding<String?>
    ) {
        self.availableTags = availableTags
        self.workoutCount = workoutCount
        self.initialStates = initialStates
        self.onCancel = onCancel
        self.onSave = onSave
        self._errorMessage = errorMessage
        _states = State(initialValue: initialStates)
    }

    private var isChanged: Bool {
        states != initialStates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Edit Tags for \(workoutCount) Runs")
                .font(.title2.weight(.semibold))

            Text("Mixed tags are applied to all selected runs when activated.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                ForEach(availableTags) { tag in
                    let state = states[tag.id] ?? .noneApplied
                    Button {
                        cycle(tagID: tag.id)
                    } label: {
                        HStack {
                            Image(systemName: icon(for: state))
                                .foregroundStyle(state == .noneApplied ? Color.secondary : Color.accentColor)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            WorkoutTagChip(name: tag.name, color: tag.color, isCompact: false)
                            Spacer()
                            Text(label(for: state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tag.name), \(label(for: state))")
                    .accessibilityHint("Activate to change assignment for all selected runs")
                }
            }
            .frame(minHeight: 240)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isChanged)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 440, minHeight: 420)
    }

    private func cycle(tagID: UUID) {
        let current = states[tagID] ?? .noneApplied
        // all → none; none → all; mixed → all (documented rule).
        switch current {
        case .allApplied:
            states[tagID] = .noneApplied
        case .noneApplied, .mixed:
            states[tagID] = .allApplied
        }
    }

    private func commit() {
        var add = Set<UUID>()
        var remove = Set<UUID>()
        for tag in availableTags {
            let initial = initialStates[tag.id] ?? .noneApplied
            let final = states[tag.id] ?? .noneApplied
            if final == initial { continue }
            switch final {
            case .allApplied:
                add.insert(tag.id)
            case .noneApplied:
                remove.insert(tag.id)
            case .mixed:
                break
            }
        }
        onSave(add, remove)
    }

    private func icon(for state: BulkTagState) -> String {
        switch state {
        case .allApplied: return "checkmark.square.fill"
        case .noneApplied: return "square"
        case .mixed: return "minus.square.fill"
        }
    }

    private func label(for state: BulkTagState) -> String {
        switch state {
        case .allApplied: return "All"
        case .noneApplied: return "None"
        case .mixed: return "Mixed"
        }
    }
}

// MARK: - Manage tags

struct ManageTagsSheet: View {
    let tags: [WorkoutTag]
    let assignmentCounts: [UUID: Int]
    let onClose: () -> Void
    let onCreate: (String, WorkoutTagColor) async -> Bool
    let onUpdate: (UUID, String, WorkoutTagColor) async -> Bool
    let onDelete: (UUID) async -> Bool
    let onReorder: ([UUID]) async -> Bool
    @Binding var errorMessage: String?

    /// Create-row draft. Kept separate from edit so Return/default-action
    /// never submits the wrong form, and canceling an edit cannot pollute Create.
    @State private var createName = ""
    @State private var createColor: WorkoutTagColor = .default
    @State private var editName = ""
    @State private var editColor: WorkoutTagColor = .default
    @State private var editingID: UUID?
    @State private var tagPendingDelete: WorkoutTag?
    @State private var orderedIDs: [UUID]
    @State private var reorderGeneration = 0

    init(
        tags: [WorkoutTag],
        assignmentCounts: [UUID: Int],
        onClose: @escaping () -> Void,
        onCreate: @escaping (String, WorkoutTagColor) async -> Bool,
        onUpdate: @escaping (UUID, String, WorkoutTagColor) async -> Bool,
        onDelete: @escaping (UUID) async -> Bool,
        onReorder: @escaping ([UUID]) async -> Bool,
        errorMessage: Binding<String?>
    ) {
        self.tags = tags
        self.assignmentCounts = assignmentCounts
        self.onClose = onClose
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onReorder = onReorder
        self._errorMessage = errorMessage
        _orderedIDs = State(initialValue: tags.map(\.id))
    }

    private var orderedTags: [WorkoutTag] {
        let byID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    private var canCreateTag: Bool {
        editingID == nil
            && !createName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSaveEdit: Bool {
        !editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Manage Tags")
                .font(.title2.weight(.semibold))

            HStack {
                TextField("New tag name", text: $createName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New tag name")
                    .disabled(editingID != nil)
                Picker("Color", selection: $createColor) {
                    ForEach(WorkoutTagColor.allCases, id: \.self) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                .frame(width: 120)
                .disabled(editingID != nil)
                Button("Create") {
                    Task {
                        let ok = await onCreate(createName, createColor)
                        if ok {
                            createName = ""
                            createColor = .default
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreateTag)
            }

            List {
                ForEach(orderedTags) { tag in
                    HStack {
                        if editingID == tag.id {
                            TextField("Name", text: $editName)
                                .textFieldStyle(.roundedBorder)
                            Picker("Color", selection: $editColor) {
                                ForEach(WorkoutTagColor.allCases, id: \.self) { color in
                                    Text(color.displayName).tag(color)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            Button("Save") {
                                Task {
                                    let ok = await onUpdate(tag.id, editName, editColor)
                                    if ok {
                                        editingID = nil
                                        editName = ""
                                        editColor = .default
                                    }
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSaveEdit)
                            Button("Cancel") {
                                editingID = nil
                                editName = ""
                                editColor = .default
                            }
                        } else {
                            WorkoutTagChip(name: tag.name, color: tag.color, isCompact: false)
                            Text("\(assignmentCounts[tag.id] ?? 0) runs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit") {
                                editingID = tag.id
                                editName = tag.name
                                editColor = tag.color
                            }
                            .disabled(editingID != nil)
                            Button("Delete", role: .destructive) {
                                tagPendingDelete = tag
                            }
                            .disabled(editingID != nil)
                        }
                    }
                }
                .onMove { source, destination in
                    let previous = orderedIDs
                    orderedIDs.move(fromOffsets: source, toOffset: destination)
                    let requested = orderedIDs
                    reorderGeneration &+= 1
                    let generation = reorderGeneration
                    Task {
                        let succeeded = await onReorder(requested)
                        if !succeeded, generation == reorderGeneration {
                            orderedIDs = previous
                        }
                    }
                }
            }
            .frame(minHeight: 260)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 480, minHeight: 460)
        .onChange(of: tags.map(\.id)) { _, newIDs in
            // Keep local order in sync when tags are created externally.
            let missing = newIDs.filter { !orderedIDs.contains($0) }
            orderedIDs.append(contentsOf: missing)
            orderedIDs.removeAll { !newIDs.contains($0) }
        }
        .alert("Delete Tag", isPresented: Binding(
            get: { tagPendingDelete != nil },
            set: { if !$0 { tagPendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { tagPendingDelete = nil }
            Button("Delete Tag", role: .destructive) {
                if let tag = tagPendingDelete {
                    Task {
                        _ = await onDelete(tag.id)
                        tagPendingDelete = nil
                    }
                }
            }
        } message: {
            if let tag = tagPendingDelete {
                let count = assignmentCounts[tag.id] ?? 0
                Text(
                    "Remove “\(tag.name)” from \(count) run\(count == 1 ? "" : "s")? "
                        + "Smart collections that use this tag will drop that criterion. "
                        + "Workouts themselves will not be deleted."
                )
            }
        }
    }
}

// MARK: - Save / manage smart collections

struct SaveSmartCollectionSheet: View {
    let suggestedSummary: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @Binding var errorMessage: String?

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Save as Smart Collection")
                .font(.title2.weight(.semibold))

            Text("Saves the current search, filters, tags, and sort. Membership updates automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(suggestedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Query summary: \(suggestedSummary)")

            TextField("Collection name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel("Collection name")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 420)
        .onAppear { focused = true }
    }
}

struct ManageSmartCollectionsSheet: View {
    let collections: [WorkoutSmartCollection]
    let tagsByID: [UUID: WorkoutTag]
    let onClose: () -> Void
    let onOpen: (UUID) -> Void
    let onRename: (UUID, String) async -> Bool
    let onDelete: (UUID) async -> Bool
    let onReorder: ([UUID]) async -> Bool
    @Binding var errorMessage: String?

    @State private var orderedIDs: [UUID]
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var pendingDelete: WorkoutSmartCollection?
    @State private var reorderGeneration = 0

    init(
        collections: [WorkoutSmartCollection],
        tagsByID: [UUID: WorkoutTag],
        onClose: @escaping () -> Void,
        onOpen: @escaping (UUID) -> Void,
        onRename: @escaping (UUID, String) async -> Bool,
        onDelete: @escaping (UUID) async -> Bool,
        onReorder: @escaping ([UUID]) async -> Bool,
        errorMessage: Binding<String?>
    ) {
        self.collections = collections
        self.tagsByID = tagsByID
        self.onClose = onClose
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
        self.onReorder = onReorder
        self._errorMessage = errorMessage
        _orderedIDs = State(initialValue: collections.map(\.id))
    }

    private var orderedCollections: [WorkoutSmartCollection] {
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Smart Collections")
                .font(.title2.weight(.semibold))

            if orderedCollections.isEmpty {
                Text("No smart collections yet. Save the current All Runs query to create one.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(orderedCollections) { collection in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if renamingID == collection.id {
                                    TextField("Name", text: $renameDraft)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Save") {
                                        Task {
                                            let ok = await onRename(collection.id, renameDraft)
                                            if ok {
                                                renamingID = nil
                                                renameDraft = ""
                                            }
                                        }
                                    }
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    Button("Cancel") {
                                        renamingID = nil
                                        renameDraft = ""
                                    }
                                } else {
                                    Text(collection.name)
                                        .font(.headline)
                                    Spacer()
                                    Button("Open") {
                                        onOpen(collection.id)
                                        onClose()
                                    }
                                    Button("Rename") {
                                        renamingID = collection.id
                                        renameDraft = collection.name
                                    }
                                    Button("Delete", role: .destructive) {
                                        pendingDelete = collection
                                    }
                                }
                            }
                            Text(
                                WorkoutSmartCollectionQuerySummary.make(
                                    query: collection.query,
                                    tagsByID: tagsByID
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { source, destination in
                        let previous = orderedIDs
                        orderedIDs.move(fromOffsets: source, toOffset: destination)
                        let requested = orderedIDs
                        reorderGeneration &+= 1
                        let generation = reorderGeneration
                        Task {
                            let succeeded = await onReorder(requested)
                            if !succeeded, generation == reorderGeneration {
                                orderedIDs = previous
                            }
                        }
                    }
                }
                .frame(minHeight: 280)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(AppDesign.Spacing.large)
        .frame(minWidth: 520, minHeight: 440)
        .onChange(of: collections.map(\.id)) { _, newIDs in
            let missing = newIDs.filter { !orderedIDs.contains($0) }
            orderedIDs.append(contentsOf: missing)
            orderedIDs.removeAll { !newIDs.contains($0) }
        }
        .alert("Delete Smart Collection", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let collection = pendingDelete {
                    Task {
                        _ = await onDelete(collection.id)
                        pendingDelete = nil
                    }
                }
            }
        } message: {
            if let collection = pendingDelete {
                Text("Delete “\(collection.name)”? Workouts and tags are not affected.")
            }
        }
    }
}
