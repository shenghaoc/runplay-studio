import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Personal Heatmap workspace: filters, statistics, Apple Maps heat cells, legend.
struct PersonalHeatmapView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: PersonalHeatmapViewModel

    @State private var displayMode: RouteMapDisplayMode = .twoD
    @State private var presentationRequest = 0

    var body: some View {
        // The window pins this stack; see `fillsWorkspace()` on the detail
        // column in ContentView. Without a definite height from there the
        // stack reports an ideal height the window cannot satisfy, and the
        // centred overflow cuts off the header and filter bar. With one, the
        // map absorbs the difference instead.
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            statisticsRow
            Divider()
            ZStack {
                mapContent
                overlayStates
            }
            Divider()
            legend
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            viewModel.refresh(workouts: appState.workouts)
        }
        .onChange(of: libraryRevision) { _, _ in
            viewModel.refresh(workouts: appState.workouts)
        }
        .onChange(of: viewModel.datePreset) { _, _ in
            viewModel.refresh(workouts: appState.workouts)
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.resolution) { _, _ in
            viewModel.refresh(workouts: appState.workouts)
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.minimumWorkoutCount) { _, _ in
            viewModel.refresh(workouts: appState.workouts)
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.routeFilter) { _, _ in
            viewModel.refresh(workouts: appState.workouts)
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.customStartDate) { _, _ in
            if viewModel.datePreset == .custom {
                viewModel.refresh(workouts: appState.workouts)
                appState.requestSessionSave()
            }
        }
        .onChange(of: viewModel.customEndDate) { _, _ in
            if viewModel.datePreset == .custom {
                viewModel.refresh(workouts: appState.workouts)
                appState.requestSessionSave()
            }
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// Invalidates heatmap work when library membership or route content changes.
    ///
    /// Hashed rather than rendered as strings: this is recomputed on every
    /// body pass, and formatting three UUID strings per workout allocated its
    /// way through the whole library on every layout tick of a window resize.
    /// It combines `PersonalHeatmapRequestKey.WorkoutRevision`, so the view
    /// invalidates on exactly the fields the view model re-keys on.
    private var libraryRevision: Int {
        var hasher = Hasher()
        for workout in appState.workouts {
            hasher.combine(PersonalHeatmapRequestKey.WorkoutRevision(workout))
        }
        return hasher.finalize()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text("Personal Heatmap")
                    .font(AppDesign.Typography.heading2)
                Text("Local coverage across your workout library. Intensity is distinct runs per cell, not GPS sample density.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if viewModel.isComputing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating heatmap")
            }
        }
        .padding(AppDesign.Spacing.xLarge)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Filters

    // The custom range gets its own row rather than widening the single bar.
    // Its two date pickers barely compress, so inline they pushed the trailing
    // Fit Heatmap button off the edge of a narrow detail column — the same
    // controls-you-cannot-reach failure the vertical fix addressed, turned
    // sideways. The window's minimum width is 720 pt (ContentView), which
    // leaves roughly 500 pt of detail column once the sidebar is showing.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            primaryFilterRow
            if viewModel.datePreset == .custom {
                customRangeRow
            }
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
    }

    private var primaryFilterRow: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            Picker("Date range", selection: $viewModel.datePreset) {
                ForEach(PersonalHeatmapDatePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Filter workouts by start date")
            .accessibilityLabel("Date range")

            Picker("Resolution", selection: $viewModel.resolution) {
                ForEach(PersonalHeatmapResolution.allCases, id: \.self) { res in
                    Text(res.helpText).tag(res)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
            .help("Cell size in metres. Broader cells are less precise but faster for large libraries.")
            .accessibilityLabel("Resolution")

            Picker("Minimum repeats", selection: $viewModel.minimumWorkoutCount) {
                ForEach(PersonalHeatmapViewModel.minimumRepeatOptions, id: \.self) { count in
                    Text(count == 1 ? "At least 1 run" : "At least \(count) runs").tag(count)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Hide cells visited by fewer than this many distinct workouts")
            .accessibilityLabel("Minimum runs per cell")

            routePicker

            Spacer()

            Button {
                viewModel.requestFit()
            } label: {
                Label("Fit Heatmap", systemImage: "viewfinder")
            }
            .help("Zoom and center the map to show all heat cells")
            .accessibilityLabel("Fit Heatmap")
            .disabled(viewModel.mapAreas.isEmpty)
        }
    }

    /// Route restriction for the heatmap. Menu style (not a plain Picker) so
    /// derived default names can be labelled without loading snapshots.
    private var routePicker: some View {
        // Derived names are set-level: a name is only disambiguated against the
        // whole sibling set, so derive once per picker build and index by id.
        // `heatmapRouteFilterTitle` is read twice below — the label and the
        // accessibility value — so it takes the already-derived names instead
        // of deriving a second and a third time. Deriving over the `prefix(15)`
        // window would name a group bare here while the Routes workspace shows
        // it with a token.
        let names = derivedRouteGroupNames
        let filterTitle = heatmapRouteFilterTitle(derivedNames: names)
        return Menu {
            Button("Any Route") { viewModel.routeFilter = .anyRoute }
                .accessibilityHint("Do not restrict the heatmap by route")
            let candidates = viewModel.routeGroups.prefix(15)
            if !candidates.isEmpty {
                Divider()
                ForEach(Array(candidates)) { group in
                    Button {
                        viewModel.routeFilter = .group(group.id)
                    } label: {
                        HStack {
                            Text(Self.heatmapRouteMenuName(for: group, derivedNames: names))
                            if case .group(let selected) = viewModel.routeFilter, selected == group.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityHint("Show heat only from runs on this route")
                }
            }
        } label: {
            Label(
                filterTitle,
                systemImage: "point.topleft.down.curvedto.point.bottomright.up"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Restrict the heatmap to one route")
        .accessibilityLabel("Route filter")
        .accessibilityValue(filterTitle)
    }

    /// Collision-aware derived names for every route group, computed from the
    /// persisted representative summaries (no snapshot loads on the filter
    /// path).
    private var derivedRouteGroupNames: [UUID: String] {
        WorkoutRouteGroup.derivedDisplayNames(
            for: viewModel.routeGroups,
            loopClosureDistanceMeters: WorkoutRouteGroup.defaultLoopClosureDistanceMeters
        )
    }

    private func heatmapRouteFilterTitle(derivedNames: [UUID: String]) -> String {
        switch viewModel.routeFilter {
        case .anyRoute:
            return String(localized: "heatmap.route.any", defaultValue: "Any Route")
        case .ungroupedOnly:
            return String(localized: "heatmap.route.ungrouped", defaultValue: "Not on a Route")
        case .group(let groupID):
            if let group = viewModel.routeGroups.first(where: { $0.id == groupID }) {
                return Self.heatmapRouteMenuName(for: group, derivedNames: derivedNames)
            }
            return String(localized: "heatmap.route.any", defaultValue: "Any Route")
        }
    }

    /// Menu label for one route group: the user name, else its entry in the
    /// set-level derived names, else the plain fallback.
    static func heatmapRouteMenuName(
        for group: WorkoutRouteGroup,
        derivedNames: [UUID: String]
    ) -> String {
        if let name = group.name, !name.isEmpty {
            return name
        }
        return derivedNames[group.id]
            ?? String(localized: "route_group.unnamed", defaultValue: "Route")
    }

    // Each picker is bounded by the other, so an inverted range cannot be
    // expressed. `makeConfiguration` still orders the pair defensively for
    // values restored from an older session.
    private var customRangeRow: some View {
        HStack(spacing: AppDesign.Spacing.medium) {
            Text("From")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            DatePicker(
                "From",
                selection: $viewModel.customStartDate,
                in: viewModel.customStartRange,
                displayedComponents: .date
            )
            .labelsHidden()
            .accessibilityLabel("Custom range start")

            Text("to")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            DatePicker(
                "To",
                selection: $viewModel.customEndDate,
                in: viewModel.customEndRange,
                displayedComponents: .date
            )
            .labelsHidden()
            .accessibilityLabel("Custom range end")

            Spacer()
        }
    }

    // MARK: - Statistics

    private var statisticsRow: some View {
        let stats = viewModel.snapshot?.statistics
        return HStack(spacing: AppDesign.Spacing.xxLarge) {
            stat("Included", value: "\(stats?.includedWorkoutCount ?? 0) runs")
            stat("Distance", value: formatDistance(stats?.totalDistanceMeters ?? 0))
            stat("Max overlap", value: maxOverlapLabel(stats?.maximumOverlap ?? 0))
            stat("Cell size", value: cellSizeLabel(stats))

            if stats?.resolutionWasAdjusted == true {
                Text("Resolution adjusted for this library.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .help("Cell size was increased so the map stays within the rendered-cell budget.")
            }

            Spacer()
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statisticsAccessibilityLabel(stats))
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(title)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppDesign.Typography.sectionHeadline)
                .monospacedDigit()
        }
    }

    // MARK: - Map

    private var mapContent: some View {
        let summary = heatmapAccessibilitySummary
        return RouteMapCanvas(
            displayMode: $displayMode,
            routes: [],
            markers: [],
            areas: viewModel.mapAreas,
            fitRequest: viewModel.fitRequest,
            presentationRequest: presentationRequest,
            controlBottomInset: 0,
            defaultDisplayMode: .twoD
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Personal route heatmap")
        .accessibilityValue(summary.spokenSummary)
        .focusedSceneValue(\.mapActions, MapActions(
            isAvailable: { !viewModel.mapAreas.isEmpty },
            fit: { viewModel.requestFit() },
            togglePresentation: {
                displayMode = displayMode == .threeD ? .twoD : .threeD
                presentationRequest += 1
            },
            canTogglePresentation: { true }
        ))
    }

    private var heatmapAccessibilitySummary: HeatmapAccessibilitySummary {
        let stats = viewModel.snapshot?.statistics
        return HeatmapAccessibilitySummary(
            includedRunCount: stats?.includedWorkoutCount ?? 0,
            totalDistanceMeters: stats?.totalDistanceMeters ?? 0,
            maximumOverlap: stats?.maximumOverlap ?? 0,
            requestedCellSizeMeters: viewModel.resolution.cellSizeMeters,
            effectiveCellSizeMeters: stats?.effectiveCellSizeMeters ?? viewModel.resolution.cellSizeMeters,
            dateFilterDescription: viewModel.datePreset.title,
            minimumRepeatCount: viewModel.minimumWorkoutCount
        )
    }

    @ViewBuilder
    private var overlayStates: some View {
        switch viewModel.loadState {
        case .loading where viewModel.snapshot == nil:
            ProgressView("Building heatmap…")
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
        case .empty(let reason):
            emptyState(reason)
        case .failed(let message):
            VStack(spacing: AppDesign.Spacing.large) {
                Text("Couldn’t build heatmap")
                    .font(AppDesign.Typography.heading3)
                Text(message)
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    viewModel.retry(workouts: appState.workouts)
                }
                .keyboardShortcut(.defaultAction)
                .help("Retry building the heatmap")
                .accessibilityLabel("Retry building heatmap")
            }
            .padding(AppDesign.Spacing.xxLarge)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func emptyState(_ reason: PersonalHeatmapEmptyReason) -> some View {
        VStack(spacing: AppDesign.Spacing.large) {
            switch reason {
            case .noGPSWorkouts:
                Text("Import GPS workouts to build your personal heatmap.")
                    .font(AppDesign.Typography.heading3)
                    .multilineTextAlignment(.center)
                Button("Import") {
                    appState.showImporter = true
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Import a GPX, TCX, FIT, or JSON workout file")
                .accessibilityLabel("Import workout file")
            case .filterExcludedAll:
                Text("No workouts match this date range.")
                    .font(AppDesign.Typography.heading3)
                HStack {
                    Button("All Time") {
                        viewModel.datePreset = .allTime
                        viewModel.refresh(workouts: appState.workouts)
                    }
                    .help("Show workouts from all time")
                    .accessibilityLabel("Show workouts from all time")

                    Button("Reset Filters") {
                        viewModel.resetFilters(workouts: appState.workouts)
                    }
                    .help("Clear all personal heatmap filters")
                    .accessibilityLabel("Reset all personal heatmap filters")
                }
            case .noCells:
                Text("No heatmap cells for the current filters.")
                    .font(AppDesign.Typography.heading3)
                Button("Reset Filters") {
                    viewModel.resetFilters(workouts: appState.workouts)
                }
                .help("Clear all personal heatmap filters")
                .accessibilityLabel("Reset all personal heatmap filters")
            }
        }
        .padding(AppDesign.Spacing.xxLarge)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.large))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Legend

    private var legend: some View {
        let maxCount = max(viewModel.snapshot?.statistics.maximumOverlap ?? 1, 1)
        let mid = max(1, maxCount / 2)
        return HStack(spacing: AppDesign.Spacing.large) {
            Text("Frequency")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)

            legendSwatch(intensity: 0.15)
            Text("1 run")
                .font(AppDesign.Typography.compactLabel)
                .monospacedDigit()

            legendSwatch(intensity: 0.55)
            Text("\(mid) runs")
                .font(AppDesign.Typography.compactLabel)
                .monospacedDigit()

            legendSwatch(intensity: 1.0)
            Text(maxCount >= 20 ? "\(maxCount)+ runs" : "\(maxCount) runs")
                .font(AppDesign.Typography.compactLabel)
                .monospacedDigit()

            Spacer()

            Text("Distinct workouts per cell · local only")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Heatmap legend. Low frequency: 1 run. Medium: \(mid) runs. High: up to \(maxCount) runs. Color shows how many distinct workouts crossed each cell."
        )
    }

    private func legendSwatch(intensity: Double) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(heatmapFill(intensity: intensity))
            .frame(width: 28, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Formatting

    private func formatDistance(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        if meters >= 1_000 {
            return String(format: "%.1f km", meters / 1_000)
        }
        return String(format: "%.0f m", meters)
    }

    private func maxOverlapLabel(_ count: Int) -> String {
        count <= 0 ? "—" : "Up to \(count) runs"
    }

    private func cellSizeLabel(_ stats: PersonalHeatmapStatistics?) -> String {
        guard let stats else { return "—" }
        let effective = Int(stats.effectiveCellSizeMeters.rounded())
        if stats.resolutionWasAdjusted {
            return "\(effective) m (adjusted)"
        }
        return "\(effective) m"
    }

    private func statisticsAccessibilityLabel(_ stats: PersonalHeatmapStatistics?) -> String {
        guard let stats else { return "Heatmap statistics unavailable" }
        return "Included \(stats.includedWorkoutCount) runs, total distance \(formatDistance(stats.totalDistanceMeters)), maximum overlap \(stats.maximumOverlap) runs, cell size \(Int(stats.effectiveCellSizeMeters.rounded())) meters"
    }
}

// MARK: - Heat color (color-blind-friendly purple/blue scale)

func heatmapFill(intensity: Double) -> Color {
    let t = min(max(intensity, 0), 1)
    // Perceptually ordered blue → purple scale (not red/green).
    // Low: light blue, high: deep purple. Opacity also scales for dark mode legibility.
    let low = Color(red: 0.35, green: 0.55, blue: 0.95)
    let high = Color(red: 0.45, green: 0.20, blue: 0.75)
    let mixed = blend(low, high, t: t)
    let opacity = 0.25 + 0.55 * t
    return mixed.opacity(opacity)
}

private func blend(_ a: Color, _ b: Color, t: Double) -> Color {
    // Approximate sRGB blend via UI-independent components where available.
    // SwiftUI Color interpolation is fine for legend/map fills.
    #if canImport(AppKit)
    let nsA = NSColor(a)
    let nsB = NSColor(b)
    guard let srgbA = nsA.usingColorSpace(.sRGB),
          let srgbB = nsB.usingColorSpace(.sRGB) else {
        // Conversion failure must not silently blend toward black (0,0,0).
        return t < 0.5 ? a : b
    }
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    srgbA.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    srgbB.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    let tt = CGFloat(t)
    return Color(
        red: Double(r1 + (r2 - r1) * tt),
        green: Double(g1 + (g2 - g1) * tt),
        blue: Double(b1 + (b2 - b1) * tt)
    )
    #else
    return t < 0.5 ? a : b
    #endif
}
