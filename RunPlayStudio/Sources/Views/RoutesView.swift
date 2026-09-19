import Accessibility
import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Routes workspace: the list of automatically grouped routes on the left,
/// the selected route's progression on the right.
///
/// Rows come from the route-groups organization; heavy matching work runs in
/// the store actor, never at view time. All manual controls (rename, merge,
/// remove run, pin representative) are context-menu and toolbar actions with
/// full keyboard/VoiceOver parity.
struct RoutesView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: RouteGroupsViewModel

    @State private var renamingGroup: RouteGroupRow?
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.rows.isEmpty {
                emptyState
            } else {
                HSplitView {
                    routeList
                        .frame(minWidth: 300, idealWidth: 360)
                    routeDetail
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Routes")
        .sheet(item: $renamingGroup) { row in
            RouteRenameSheet(
                initialName: row.displayName,
                isUserNamed: row.userNamed
            ) { newName in
                Task {
                    await appState.renameRouteGroup(id: row.id, name: newName)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            Label(
                viewModel.pendingAssignmentCount > 0
                    ? String(
                        format: String(localized: "route_group.header.pending", defaultValue: "%d routes · %d runs awaiting analysis"),
                        viewModel.rows.count,
                        viewModel.pendingAssignmentCount
                    )
                    : String(
                        format: String(localized: "route_group.header", defaultValue: "%d routes"),
                        viewModel.rows.count
                    ),
                systemImage: "point.topleft.down.curvedto.point.bottomright.up"
            )
            .font(AppDesign.Typography.sectionHeadline)
            .accessibilityLabel(
                viewModel.pendingAssignmentCount > 0
                    ? String(
                        format: String(localized: "route_group.header.pending.ax", defaultValue: "%d routes, %d runs awaiting route analysis"),
                        viewModel.rows.count,
                        viewModel.pendingAssignmentCount
                    )
                    : String(
                        format: String(localized: "route_group.header.ax", defaultValue: "%d routes"),
                        viewModel.rows.count
                    )
            )

            Spacer()

            if viewModel.isAssigning {
                HStack(spacing: AppDesign.Spacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing routes…")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Analyzing routes")
            }

            if viewModel.isReclustering {
                HStack(spacing: AppDesign.Spacing.small) {
                    ProgressView(value: Double(viewModel.reclusterCompletedCount), total: Double(max(viewModel.reclusterTotalCount, 1)))
                        .frame(width: 140)
                    Text("\(viewModel.reclusterCompletedCount)/\(viewModel.reclusterTotalCount)")
                        .font(AppDesign.Typography.compactLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        appState.cancelRouteGroupRecluster()
                    }
                    .accessibilityHint("Stops the re-cluster and keeps the previous routes")
                }
                .accessibilityElement(children: .contain)
            } else {
                Button {
                    appState.reclusterRouteGroups()
                } label: {
                    Label("Re-cluster Routes", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Recompute every route group from scratch with progress and cancellation")
                .accessibilityLabel("Re-cluster routes")
                .accessibilityHint("Recomputes every route group from scratch")
                .disabled(!appState.hasPersistedLibrary || appState.workouts.isEmpty || appState.isRouteGroupPassRunning)
            }

            if let summary = viewModel.lastReclusterSummary {
                Text(summary)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppDesign.Spacing.large)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AppDesign.Spacing.xLarge) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No routes yet")
                .font(AppDesign.Typography.sectionHeadline)
            Text(
                appState.hasPersistedLibrary && !appState.workouts.isEmpty
                    ? "Run route grouping across your library to find the routes you repeat."
                    : "Import runs first; routes group runs that follow substantially the same path."
            )
            .font(AppDesign.Typography.metricLabel)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            if appState.hasPersistedLibrary && !appState.workouts.isEmpty {
                Button {
                    appState.reclusterRouteGroups()
                } label: {
                    Label("Group Routes Now", systemImage: "wand.and.stars")
                        .padding(.horizontal, AppDesign.Spacing.xLarge)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Groups every library run onto routes")
                .disabled(appState.isRouteGroupPassRunning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppDesign.Spacing.xxLarge)
    }

    // MARK: - Route list

    private var routeList: some View {
        List(viewModel.rows, selection: Binding(
            get: { viewModel.selectedGroupID },
            set: { viewModel.selectedGroupID = $0 }
        )) { row in
            RouteGroupListRow(row: row)
                .tag(row.id)
                .contextMenu {
                    Button {
                        renameDraft = row.userNamed ? row.displayName : ""
                        renamingGroup = row
                    } label: {
                        Label("Rename Route…", systemImage: "pencil")
                    }
                    .accessibilityHint("Rename this route")

                    mergeMenu(for: row)
                }
        }
        .overlay {
            if viewModel.selectedGroupID == nil, !viewModel.rows.isEmpty {
                Text("Select a route to see its runs and pace progression")
                    .font(AppDesign.Typography.metricLabel)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Merge submenu listing every other group, capped at a bounded count to
    /// keep the menu usable in very large libraries.
    @ViewBuilder
    private func mergeMenu(for row: RouteGroupRow) -> some View {
        let others = viewModel.rows.filter { $0.id != row.id }.prefix(12)
        if others.isEmpty {
            Button {} label: {
                Label("Merge into…", systemImage: "arrow.merge.to.line")
            }
            .disabled(true)
        } else {
            Menu {
                ForEach(Array(others)) { other in
                    Button(other.displayName) {
                        Task {
                            await appState.mergeRouteGroups(sourceID: row.id, into: other.id)
                        }
                    }
                    .accessibilityHint("Merge this route into \(other.displayName)")
                }
            } label: {
                Label("Merge into…", systemImage: "arrow.merge.to.line")
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var routeDetail: some View {
        if let groupID = viewModel.selectedGroupID {
            RouteGroupDetailView(
                appState: appState,
                viewModel: viewModel,
                groupID: groupID,
                onRename: { row in
                    renameDraft = row.userNamed ? row.displayName : ""
                    renamingGroup = row
                }
            )
            .id(groupID)
        } else {
            Color.clear
        }
    }
}

/// One row of the route list.
private struct RouteGroupListRow: View {
    let row: RouteGroupRow

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
            HStack(spacing: AppDesign.Spacing.small) {
                Text(row.displayName)
                    .font(AppDesign.Typography.sectionHeadline)
                Spacer()
                Text("\(row.runCount)")
                    .font(AppDesign.Typography.compactMetric)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: AppDesign.Spacing.large) {
                if let last = row.lastRunDate {
                    Text(last, format: .dateTime.month(.abbreviated).day().year())
                }
                Text(DisplayFormatter.formatDistance(row.representativeDistanceMeters))
                if let best = row.bestPaceSecondsPerKilometer {
                    Text("Best \(DisplayFormatter.formatPaceShort(best))")
                }
            }
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, AppDesign.Spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [row.displayName]
        parts.append(String(
            format: String(localized: "route_group.row.runs.ax", defaultValue: "%d runs"),
            row.runCount
        ))
        if let best = row.bestPaceSecondsPerKilometer {
            parts.append(String(
                format: String(localized: "route_group.row.best.ax", defaultValue: "best active pace %@"),
                DisplayFormatter.formatPace(best)
            ))
        }
        return parts.joined(separator: ", ")
    }
}

/// Rename sheet shared by the list context menu and the detail toolbar.
private struct RouteRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    private let isUserNamed: Bool
    private let onCommit: (String?) -> Void

    init(initialName: String, isUserNamed: Bool, onCommit: @escaping (String?) -> Void) {
        _name = State(initialValue: isUserNamed ? initialName : "")
        self.isUserNamed = isUserNamed
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.large) {
            Text("Rename Route")
                .font(AppDesign.Typography.sectionHeadline)
            TextField("Route name", text: $name)
                .textFieldStyle(.roundedBorder)
                .help("A custom name for this route; leave empty to use the derived default")
            Text("Leave the name empty to return to the automatic description.")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    onCommit(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.count > 120)
            }
        }
        .padding(AppDesign.Spacing.xLarge)
        .frame(width: 360)
    }
}
