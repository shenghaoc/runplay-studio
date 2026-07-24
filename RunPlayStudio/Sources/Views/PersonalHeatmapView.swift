import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Personal Heatmap workspace: filters, statistics, Apple Maps heat cells, legend.
struct PersonalHeatmapView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: PersonalHeatmapViewModel

    @State private var displayMode: RouteMapDisplayMode = .twoD

    var body: some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private var libraryRevision: [String] {
        appState.workouts.map { workout in
            "\(workout.id.uuidString):\(workout.normalizationVersion):\(workout.routePoints.count):\(workout.routePoints.first?.id.uuidString ?? "-"):\(workout.routePoints.last?.id.uuidString ?? "-")"
        }
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

    private var filterBar: some View {
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

            if viewModel.datePreset == .custom {
                DatePicker(
                    "From",
                    selection: $viewModel.customStartDate,
                    displayedComponents: .date
                )
                .labelsHidden()
                .accessibilityLabel("Custom range start")

                Text("–")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                DatePicker(
                    "To",
                    selection: $viewModel.customEndDate,
                    displayedComponents: .date
                )
                .labelsHidden()
                .accessibilityLabel("Custom range end")
            }

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
        .padding(.horizontal, AppDesign.Spacing.xLarge)
        .padding(.vertical, AppDesign.Spacing.medium)
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
        RouteMapCanvas(
            displayMode: $displayMode,
            routes: [],
            markers: [],
            areas: viewModel.mapAreas,
            fitRequest: viewModel.fitRequest,
            controlBottomInset: 0,
            defaultDisplayMode: .twoD
        )
        .accessibilityLabel("Personal route heatmap")
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
            case .filterExcludedAll:
                Text("No workouts match this date range.")
                    .font(AppDesign.Typography.heading3)
                HStack {
                    Button("All Time") {
                        viewModel.datePreset = .allTime
                        viewModel.refresh(workouts: appState.workouts)
                    }
                    Button("Reset Filters") {
                        viewModel.resetFilters(workouts: appState.workouts)
                    }
                }
            case .noCells:
                Text("No heatmap cells for the current filters.")
                    .font(AppDesign.Typography.heading3)
                Button("Reset Filters") {
                    viewModel.resetFilters(workouts: appState.workouts)
                }
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
