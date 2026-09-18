import SwiftUI
import RunPlayCore

/// Personal Records workspace: the scoped standing-best table plus each
/// record's improvement history.
///
/// Rows derive from stored per-workout record windows and summaries. The
/// one-off library backfill runs inline with progress and Cancel the first
/// time the workspace opens over a library that predates record computation.
struct PersonalRecordsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: PersonalRecordsViewModel

    @State private var selectedCategory: PersonalRecordCategory?

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            backfillBanner
            content
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { appState.refreshPersonalRecords() }
        .onChange(of: appState.workouts.count) {
            appState.refreshPersonalRecords()
            appState.startPersonalRecordsBackfillIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text("Records")
                    .font(AppDesign.Typography.heading2)
                Text("Standing personal records across the scoped runs. A window longer than any single run is not attempted; equal efforts never replace the earlier holder. Select a record to see its improvement history.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if viewModel.isComputing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating records")
            }
        }
        .padding(AppDesign.Spacing.xLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.accessibilitySummary()?.spokenSummary ?? "Personal records")
    }

    // MARK: - Filters

    private var filterBar: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            scopePicker
            Spacer()
            Text("\(viewModel.snapshot?.includedWorkoutCount ?? 0) runs in scope")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
    }

    private var scopePicker: some View {
        Picker("Scope", selection: scopeBinding) {
            Text("All Workouts").tag(WorkoutTrendsScope.entireLibrary)
            Text("Current All Runs Filter").tag(WorkoutTrendsScope.currentLibraryFilter)
            ForEach(appState.smartCollections) { collection in
                Text(collection.name).tag(WorkoutTrendsScope.smartCollection(collection.id))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 240)
        .help("Limit records to the whole library, the current All Runs query, or one smart collection")
        .accessibilityLabel("Records scope")
    }

    /// Picks scope; a smart-collection tag needs the collection to still exist.
    private var scopeBinding: Binding<WorkoutTrendsScope> {
        Binding<WorkoutTrendsScope>(
            get: { viewModel.scope },
            set: { newValue in
                if case .smartCollection(let id) = newValue,
                   !appState.smartCollections.contains(where: { $0.id == id }) {
                    return
                }
                viewModel.scope = newValue
                appState.refreshPersonalRecords()
            }
        )
    }

    // MARK: - Backfill

    @ViewBuilder
    private var backfillBanner: some View {
        switch viewModel.backfillState {
        case .idle:
            EmptyView()
        case .running(let completed, let total, let currentName):
            HStack(spacing: AppDesign.Spacing.medium) {
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                    .frame(maxWidth: 260)
                Text("Computing records — \(completed) of \(total) runs")
                    .font(AppDesign.Typography.compactLabel)
                    .monospacedDigit()
                if !currentName.isEmpty {
                    Text(currentName)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") {
                    appState.cancelPersonalRecordsBackfill()
                }
                .accessibilityHint("Keeps every completed run; the pass resumes next time you open Records")
            }
            .padding(.horizontal, AppDesign.Spacing.xLarge)
            .padding(.vertical, AppDesign.Spacing.medium)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Computing personal records, \(completed) of \(total) runs")
        case .failed(let message):
            HStack(spacing: AppDesign.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, AppDesign.Spacing.xLarge)
            .padding(.vertical, AppDesign.Spacing.medium)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            VStack {
                Spacer()
                ProgressView(viewModel.loadState == .loading ? "Computing records…" : "Loading…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty(let reason):
            VStack(spacing: AppDesign.Spacing.medium) {
                Spacer()
                Image(systemName: "stopwatch")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(emptyReasonText(reason))
                    .font(AppDesign.Typography.sectionHeadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack {
                Spacer()
                Text("Records could not be computed.\n\(message)")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            recordsTable
        }
    }

    private func emptyReasonText(_ reason: PersonalRecordsEmptyReason) -> String {
        switch reason {
        case .noWorkouts:
            return "Import a run to start collecting records."
        case .scopeExcludedAll:
            return "No runs match the current records scope."
        }
    }

    private var recordsTable: some View {
        Table(viewModel.snapshot?.rows ?? [], selection: $selectedCategory) {
            TableColumn("Record") { row in
                Text(row.category.displayName)
                    .font(AppDesign.Typography.sectionHeadline)
            }
            .width(min: 140, ideal: 180)

            TableColumn("Time / Value") { row in
                Text(valueText(for: row))
                    .font(AppDesign.Typography.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(row.best == nil ? .secondary : .primary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Heart Rate") { row in
                Text(heartRateText(for: row))
                    .font(AppDesign.Typography.metricValue)
                    .monospacedDigit()
                    .foregroundStyle(row.best?.averageHeartRateBPM == nil ? .secondary : .primary)
            }
            .width(min: 70, ideal: 80)

            TableColumn("Date") { row in
                Text(row.best.map { Self.dateText($0.date) } ?? "—")
                    .font(AppDesign.Typography.compactLabel)
                    .monospacedDigit()
                    .foregroundStyle(row.best == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Workout") { row in
                Text(row.best?.workoutName ?? "Not attempted")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(row.best == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .overlay(alignment: .bottom) {
            historyInspector
        }
    }

    /// History of the selected record plus the keyboard/VoiceOver open path.
    @ViewBuilder
    private var historyInspector: some View {
        if let selectedCategory,
           let row = viewModel.snapshot?.row(for: selectedCategory) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                HStack(spacing: AppDesign.Spacing.medium) {
                    Text("\(row.category.displayName) — improvement history")
                        .font(AppDesign.Typography.sectionHeadline)
                    if let best = row.best {
                        Button {
                            appState.openPersonalRecord(best)
                        } label: {
                            Label("View Workout", systemImage: "map")
                        }
                        .accessibilityHint("Opens the workout holding this record and highlights the window")
                    }
                    Spacer()
                }
                if row.history.isEmpty {
                    Text("Not attempted in this scope.")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                } else {
                    // Newest first: the standing record leads the list.
                    ForEach(row.history.reversed()) { effort in
                        Button {
                            appState.openPersonalRecord(effort)
                        } label: {
                            HStack(spacing: AppDesign.Spacing.large) {
                                Text(Self.dateText(effort.date))
                                    .font(AppDesign.Typography.compactLabel)
                                    .monospacedDigit()
                                    .frame(width: 100, alignment: .leading)
                                Text(effortValueText(effort, category: row.category))
                                    .font(AppDesign.Typography.metricValue)
                                    .monospacedDigit()
                                    .frame(width: 90, alignment: .leading)
                                Text(effort.workoutName)
                                    .font(AppDesign.Typography.compactLabel)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .accessibilityLabel(accessibilityLabel(for: effort, category: row.category))
                        .accessibilityHint("Opens that workout and highlights the record window")
                    }
                }
            }
            .padding(AppDesign.Spacing.medium)
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: .top) {
                Divider()
            }
            .padding(.horizontal, AppDesign.Spacing.xSmall)
            .padding(.bottom, AppDesign.Spacing.xSmall)
        }
    }

    // MARK: - Formatting

    private func valueText(for row: PersonalRecordRow) -> String {
        guard let best = row.best else { return "—" }
        if row.category.isPaceWindow {
            return DisplayFormatter.formatPaceShort(best.value)
        }
        if row.category == .biggestAscent {
            return DisplayFormatter.formatElevation(best.value)
        }
        return DisplayFormatter.formatDistanceKm(best.value)
    }

    private func heartRateText(for row: PersonalRecordRow) -> String {
        guard let heartRate = row.best?.averageHeartRateBPM,
              row.category.isPaceWindow else {
            return "—"
        }
        return "\(Int(heartRate))"
    }

    private func effortValueText(
        _ effort: PersonalRecordEffort,
        category: PersonalRecordCategory
    ) -> String {
        if category.isPaceWindow {
            return DisplayFormatter.formatPaceShort(effort.value)
        }
        if category == .biggestAscent {
            return DisplayFormatter.formatElevation(effort.value)
        }
        return DisplayFormatter.formatDistanceKm(effort.value)
    }

    private func accessibilityLabel(
        for effort: PersonalRecordEffort,
        category: PersonalRecordCategory
    ) -> String {
        let value = effortValueText(effort, category: category)
        if category.isPaceWindow {
            return "\(category.displayName) \(value) per kilometre, \(effort.workoutName), \(Self.dateText(effort.date))"
        }
        return "\(category.displayName) \(value), \(effort.workoutName), \(Self.dateText(effort.date))"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
