import Accessibility
import Charts
import RunPlayCore
import SwiftUI

/// Trends workspace: period/range/scope filters, four Swift Charts trend
/// panels, a hover/keyboard inspector, and navigation into a period-filtered
/// All Runs view.
struct TrendsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: TrendsViewModel

    /// Period inspected through hover or the keyboard picker.
    @State private var inspectedKey: WorkoutTrendsPeriodKey?

    var body: some View {
        // The window pins this stack; see `fillsWorkspace()` on the detail
        // column in ContentView. Without a definite height from there the
        // ideal height of four chart panels inflates the split view past the
        // window and the centred overflow cuts off the header and filter bar.
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            ScrollView {
                VStack(spacing: AppDesign.Spacing.large) {
                    statisticsRow
                    if viewModel.showsInProgressPeriod {
                        Text("The latest \(viewModel.period.title.lowercased()) is still in progress.")
                            .font(AppDesign.Typography.compactLabel)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    chartPanels
                    trainingLoadSection
                    inspector
                    notes
                }
                .padding(AppDesign.Spacing.xLarge)
            }
            overlayStates
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            appState.refreshTrends()
        }
        .onChange(of: libraryRevision) { _, _ in
            appState.refreshTrends()
        }
        .onChange(of: viewModel.period) { _, _ in
            inspectedKey = nil
            appState.refreshTrends()
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.range) { _, _ in
            inspectedKey = nil
            appState.refreshTrends()
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.scope) { _, _ in
            inspectedKey = nil
            appState.refreshTrends()
            appState.requestSessionSave()
        }
        .onChange(of: viewModel.ctlTimeConstantDays) { _, _ in
            appState.refreshTrends()
        }
        .onChange(of: viewModel.atlTimeConstantDays) { _, _ in
            appState.refreshTrends()
        }
        .onChange(of: viewModel.includeEstimatedLoads) { _, _ in
            appState.refreshTrends()
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    /// Invalidates trends work when library membership or summaries change.
    ///
    /// Hashed rather than rendered as strings: this is recomputed on every
    /// body pass, and formatting one UUID string per workout allocated its way
    /// through the whole library each time the mouse moved over a chart.
    private var libraryRevision: Int {
        var hasher = Hasher()
        for workout in appState.workouts {
            hasher.combine(workout.id)
            hasher.combine(workout.analysisVersion)
            hasher.combine(workout.metadata.startDate)
            hasher.combine(workout.metadata.recordedUTCOffsetSeconds)
            hasher.combine(workout.trainingLoad)
        }
        return hasher.finalize()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text("Trends")
                    .font(AppDesign.Typography.heading2)
                Text("Whole-library trends by \(viewModel.period.title.lowercased()). Totals use active time; pauses never contribute. Missing heart-rate or elevation shows as a gap, not zero.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if viewModel.isComputing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Updating trends")
            }
        }
        .padding(AppDesign.Spacing.xLarge)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Filters

    private var filterBar: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            Picker("Period", selection: $viewModel.period) {
                ForEach(WorkoutTrendsPeriod.allCases, id: \.self) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 120)
            .help("Group workouts by ISO week, calendar month, or calendar year")
            .accessibilityLabel("Trends period")

            Picker("Range", selection: $viewModel.range) {
                ForEach(WorkoutTrendsRange.allCases, id: \.self) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Show whole periods covering the selected time range")
            .accessibilityLabel("Trends range")

            scopePicker
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
        .help("Limit trends to the whole library, the current All Runs query, or one smart collection")
        .accessibilityLabel("Trends scope")
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
            }
        )
    }

    // MARK: - Statistics

    private var statisticsRow: some View {
        HStack(alignment: .top, spacing: AppDesign.Spacing.xxxLarge) {
            stat(
                title: "Distance",
                value: DisplayFormatter.formatDistanceKm(viewModel.aggregation?.totalDistanceMeters ?? 0)
            )
            stat(title: "Active Time", value: DisplayFormatter.formatDuration(viewModel.aggregation?.totalActiveSeconds ?? 0))
            stat(title: "Runs", value: "\(viewModel.aggregation?.includedRunCount ?? 0)")
            stat(
                title: "Mean Pace",
                value: (viewModel.aggregation?.meanActivePaceSecondsPerKilometer).map(DisplayFormatter.formatPace) ?? "—"
            )
            stat(
                title: "Mean HR",
                value: heartRateStat,
                caption: heartRateCaption
            )
            stat(
                title: "Ascent",
                value: DisplayFormatter.formatElevation(viewModel.aggregation?.totalAscentMeters),
                caption: ascentCaption
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.accessibilitySummary()?.spokenSummary ?? "Trends")
    }

    private var heartRateStat: String {
        guard let heartRate = viewModel.aggregation?.meanHeartRateBPM else { return "—" }
        return "\(Int(heartRate)) bpm"
    }

    private var heartRateCaption: String? {
        guard let aggregation = viewModel.aggregation,
              aggregation.meanHeartRateBPM != nil,
              aggregation.heartRateContributingRuns < aggregation.includedRunCount else {
            return nil
        }
        return "from \(aggregation.heartRateContributingRuns) of \(aggregation.includedRunCount) runs"
    }

    private var ascentCaption: String? {
        guard let aggregation = viewModel.aggregation,
              aggregation.totalAscentMeters != nil,
              aggregation.ascentContributingRuns < aggregation.includedRunCount else {
            return nil
        }
        return "from \(aggregation.ascentContributingRuns) of \(aggregation.includedRunCount) runs"
    }

    private func stat(title: String, value: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
            Text(title)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppDesign.Typography.metricValue)
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Charts

    @ViewBuilder
    private var chartPanels: some View {
        if let aggregation = viewModel.aggregation {
            VStack(spacing: AppDesign.Spacing.xLarge) {
                TrendsChartPanel(
                    metric: .distance,
                    points: viewModel.chartPoints(for: .distance),
                    color: AppDesign.MetricColor.distance,
                    spokenSummary: viewModel.chartAccessibilitySummary(for: .distance).spokenSummary,
                    onHoverPeriod: { inspectedKey = $0 },
                    onNavigate: navigate
                )
                TrendsChartPanel(
                    metric: .pace,
                    points: viewModel.chartPoints(for: .pace),
                    color: AppDesign.MetricColor.pace,
                    spokenSummary: viewModel.chartAccessibilitySummary(for: .pace).spokenSummary,
                    onHoverPeriod: { inspectedKey = $0 },
                    onNavigate: navigate
                )
                TrendsChartPanel(
                    metric: .heartRate,
                    points: viewModel.chartPoints(for: .heartRate),
                    color: AppDesign.MetricColor.heartRate,
                    spokenSummary: viewModel.chartAccessibilitySummary(for: .heartRate).spokenSummary,
                    onHoverPeriod: { inspectedKey = $0 },
                    onNavigate: navigate
                )
                TrendsChartPanel(
                    metric: .ascent,
                    points: viewModel.chartPoints(for: .ascent),
                    color: AppDesign.MetricColor.elevation,
                    spokenSummary: viewModel.chartAccessibilitySummary(for: .ascent).spokenSummary,
                    onHoverPeriod: { inspectedKey = $0 },
                    onNavigate: navigate
                )
            }
            .disabled(aggregation.buckets.isEmpty)
        }
    }

    private func navigate(_ key: WorkoutTrendsPeriodKey) {
        guard let bucket = viewModel.aggregation?.buckets.first(where: { $0.id == key }),
              bucket.runCount > 0 else {
            return
        }
        appState.showWorkoutsInTrendsPeriod(key)
    }

    // MARK: - Training load

    /// Backfill banner, the fitness/fatigue/form chart, its honesty
    /// captions, and the model preference controls.
    @ViewBuilder
    private var trainingLoadSection: some View {
        trainingLoadBackfillBanner
        if let series = viewModel.trainingLoad {
            TrainingLoadChartPanel(
                series: series,
                spokenSummary: viewModel.trainingLoadChartAccessibilitySummary()?.spokenSummary ?? "Training load.",
                ctlTimeConstantDays: $viewModel.ctlTimeConstantDays,
                atlTimeConstantDays: $viewModel.atlTimeConstantDays,
                includeEstimatedLoads: $viewModel.includeEstimatedLoads
            )
        }
    }

    @ViewBuilder
    private var trainingLoadBackfillBanner: some View {
        switch viewModel.trainingLoadBackfillState {
        case .idle:
            EmptyView()
        case .running(let completed, let total, let name):
            VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                Text("Computing training load for earlier runs")
                    .font(AppDesign.Typography.compactLabel)
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0) {
                    Text("\(completed) of \(total) runs\(name.isEmpty ? "" : " — \(name)")")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppDesign.Spacing.large)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Text(message)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .padding(AppDesign.Spacing.large)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Inspector

    /// Hover-driven period detail plus a keyboard/VoiceOver navigation path.
    private var inspector: some View {
        HStack(spacing: AppDesign.Spacing.medium) {
            Picker("Period detail", selection: inspectorBinding) {
                Text("None").tag(WorkoutTrendsPeriodKey?.none)
                ForEach(recentKeys, id: \.self) { key in
                    if let key {
                        Text(viewModel.periodLabel(for: key)).tag(WorkoutTrendsPeriodKey?.some(key))
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
            .accessibilityLabel("Inspect trends period")

            if let inspected = inspectedDetail {
                Text(inspected)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let key = resolvedInspectedKey, inspectedRunCount > 0 {
                    Button {
                        navigate(key)
                    } label: {
                        Label("View Runs (\(inspectedRunCount))", systemImage: "list.bullet")
                    }
                    .accessibilityLabel(
                        inspectedRunCount == 1
                            ? "View the 1 run in \(viewModel.periodLabel(for: key))"
                            : "View the \(inspectedRunCount) runs in \(viewModel.periodLabel(for: key))"
                    )
                }
            }
            Spacer()
        }
    }

    /// Bounded most-recent period list (newest first) for the keyboard path.
    ///
    /// A period inspected by hovering an older bar is added even when it falls
    /// outside the bound, so the picker's selection always has a matching tag.
    private var recentKeys: [WorkoutTrendsPeriodKey?] {
        let keys = viewModel.aggregation?.buckets.map(\.id) ?? []
        var recent = Array(keys.suffix(60))
        if let inspected = resolvedInspectedKey, !recent.contains(inspected) {
            recent.insert(inspected, at: 0)
        }
        return recent.reversed().map { Optional($0) }
    }

    /// The inspected period only while the current window still contains it.
    /// A scope or range change can retire a period out from under the hover.
    private var resolvedInspectedKey: WorkoutTrendsPeriodKey? {
        guard let inspectedKey, viewModel.containsPeriod(inspectedKey) else { return nil }
        return inspectedKey
    }

    private var inspectorBinding: Binding<WorkoutTrendsPeriodKey?> {
        Binding<WorkoutTrendsPeriodKey?>(
            get: { resolvedInspectedKey },
            set: { inspectedKey = $0 }
        )
    }

    private var inspectedDetail: String? {
        guard let key = resolvedInspectedKey,
              let bucket = viewModel.aggregation?.buckets.first(where: { $0.id == key }) else {
            return nil
        }
        var parts: [String] = [
            viewModel.periodLabel(for: key),
            "\(bucket.runCount) run\(bucket.runCount == 1 ? "" : "s")",
            DisplayFormatter.formatDistanceKm(bucket.totalDistanceMeters)
        ]
        if let pace = bucket.meanActivePaceSecondsPerKilometer {
            parts.append("\(DisplayFormatter.formatPace(pace)) /km")
        }
        if let heartRate = bucket.meanHeartRateBPM {
            let qualifier = bucket.heartRateContributingRuns < bucket.runCount
                ? " (from \(bucket.heartRateContributingRuns) of \(bucket.runCount) runs)"
                : ""
            parts.append("\(Int(heartRate)) bpm\(qualifier)")
        }
        if let ascent = bucket.totalAscentMeters {
            let qualifier = bucket.ascentContributingRuns < bucket.runCount
                ? " (from \(bucket.ascentContributingRuns) of \(bucket.runCount) runs)"
                : ""
            parts.append("\(DisplayFormatter.formatElevation(ascent)) ascent\(qualifier)")
        }
        return parts.joined(separator: " · ")
    }

    private var inspectedRunCount: Int {
        guard let key = resolvedInspectedKey else { return 0 }
        return viewModel.aggregation?.buckets.first(where: { $0.id == key })?.runCount ?? 0
    }

    private var notes: some View {
        Text("Runs count entirely in the period they start in, on their recorded local date. “Last N months” always starts on a whole period. Ascent uses corrected elevation when available, otherwise the raw source ascent.")
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Overlay states

    @ViewBuilder
    private var overlayStates: some View {
        switch viewModel.loadState {
        case .idle, .loading, .ready:
            EmptyView()
        case .empty(let reason):
            emptyState(reason)
        case .failed(let message):
            ContentUnavailableView {
                Label("Trends Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ reason: TrendsEmptyReason) -> some View {
        switch reason {
        case .noWorkouts:
            ContentUnavailableView {
                Label("No Workouts", systemImage: "chart.bar.xaxis")
            } description: {
                Text("Import workouts to see distance, pace, heart-rate, and ascent trends over time.")
            }
        case .noDatedWorkouts:
            ContentUnavailableView {
                Label("No Dated Workouts", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("None of your workouts carries a start date, so they cannot be placed on a timeline.")
            }
        case .scopeExcludedAll:
            ContentUnavailableView {
                Label("No Runs In Scope", systemImage: "line.diagonal")
            } description: {
                Text("The selected scope matches no workouts. Try All Workouts or another collection.")
            }
        }
    }
}

/// Daily load bars plus fitness, fatigue, and form lines.
///
/// Colors stay inside the semantic palette: red for heart-rate effort (the
/// bars), green for fitness, orange for fatigue (the strain axis), blue for
/// form. Estimated days render lighter and are never part of the model
/// unless explicitly opted in; days with runs but no heart rate draw a
/// hollow marker so zero-contribution never reads as a rest day.
private struct TrainingLoadChartPanel: View {
    let series: FitnessFatigueSeries
    let spokenSummary: String
    @Binding var ctlTimeConstantDays: Double
    @Binding var atlTimeConstantDays: Double
    @Binding var includeEstimatedLoads: Bool

    @State private var hoveredDayIndex: Int?

    private var loadColor: Color { AppDesign.MetricColor.heartRate }
    private var fitnessColor: Color { AppDesign.MetricColor.elevation }
    private var fatigueColor: Color { AppDesign.MetricColor.speed }
    private var formColor: Color { AppDesign.MetricColor.distance }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("Training Load")
                    .font(AppDesign.Typography.sectionHeadline)
                Spacer()
                Text("TRIMP by day · Fitness \(Int(ctlTimeConstantDays)) d · Fatigue \(Int(atlTimeConstantDays)) d")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
            captions
            if series.loadDays.contains(where: { $0.runCount > 0 }) {
                chart
            } else {
                Text("No dated runs in this scope.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
            hoveredReadout
            controls
        }
        .padding(AppDesign.Spacing.large)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    /// Honesty captions: estimated exclusion and HR coverage.
    private var captions: some View {
        var parts: [String] = []
        if series.includesEstimatedLoads {
            parts.append("Estimated loads are included in the model at your request — they are invented values and make the curve less trustworthy.")
        } else {
            parts.append("Fitness, fatigue, and form use measured heart-rate loads only. Estimated loads are shown on the bars but excluded from the model.")
        }
        if let coverage = series.hrCoverageFraction {
            parts.append("Heart-rate coverage: \(Int((coverage * 100).rounded()))% of days with runs.")
        }
        return Text(parts.joined(separator: " "))
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var chart: some View {
        Chart {
            ForEach(series.loadDays.indices, id: \.self) { index in
                let day = series.loadDays[index]
                let model = series.modelDays[index]
                if day.runCount > 0 {
                    if day.contribution == .hrDay {
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Load", day.measuredLoad)
                        )
                        .foregroundStyle(loadColor.opacity(0.55))
                        .cornerRadius(1)
                    }
                    // Estimated load always draws at its height — the
                    // caption promises the bars show it — but far lighter
                    // than measured, and it never joins the model unless
                    // opted in.
                    if day.estimatedLoad > 0 {
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Load", day.estimatedLoad)
                        )
                        .foregroundStyle(loadColor.opacity(0.18))
                        .cornerRadius(1)
                    }
                    // A run day with no load at all (un-backfilled) still
                    // gets a floor marker so it never reads as a rest day.
                    if day.contribution == .noHRData, day.estimatedLoad == 0 {
                        PointMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Load", 0)
                        )
                        .symbol(.circle)
                        .foregroundStyle(loadColor.opacity(0.35))
                    }
                }
                LineMark(
                    x: .value("Day", model.date, unit: .day),
                    y: .value("Fitness", model.ctl),
                    series: .value("Series", "fitness")
                )
                .foregroundStyle(fitnessColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
                LineMark(
                    x: .value("Day", model.date, unit: .day),
                    y: .value("Fatigue", model.atl),
                    series: .value("Series", "fatigue")
                )
                .foregroundStyle(fatigueColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
                LineMark(
                    x: .value("Day", model.date, unit: .day),
                    y: .value("Form", model.tsb),
                    series: .value("Series", "form")
                )
                .foregroundStyle(formColor.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month, count: 1)) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated).year(), centered: false)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let numeric = value.as(Double.self) {
                        Text("\(Int(numeric))")
                    }
                }
            }
        }
        .chartLegend(position: .bottom, spacing: AppDesign.Spacing.medium)
        .frame(minHeight: 220)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoveredDayIndex = dayIndex(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hoveredDayIndex = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Training load by day")
        .accessibilityValue(spokenSummary)
        .accessibilityChartDescriptor(
            TrainingLoadChartDescriptor(series: series, summary: spokenSummary)
        )
    }

    /// Hover / scrub readout: the values the user most needs spoken or read.
    private var hoveredReadout: some View {
        Group {
            if let index = hoveredDayIndex,
               index < series.loadDays.count, index < series.modelDays.count {
                let day = series.loadDays[index]
                let model = series.modelDays[index]
                Text(TrainingLoadChartAccessibilitySummary.dayPhrase(
                    load: day.contribution == .hrDay ? day.measuredLoad : day.estimatedLoad,
                    estimatedLoad: day.contribution != .hrDay && day.estimatedLoad > 0,
                    ctl: model.ctl,
                    atl: model.atl,
                    tsb: model.tsb,
                    hasHRData: day.contribution == .hrDay
                ) + " · " + day.date.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppDesign.Typography.compactLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Hover the chart to read one day's load, fitness, fatigue, and form.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Time constants and the estimated-inclusion opt-in.
    private var controls: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            Stepper(
                "Fitness \(Int(ctlTimeConstantDays)) days",
                value: $ctlTimeConstantDays,
                in: 7...90,
                step: 1
            )
            .frame(maxWidth: 180)
            .help("Chronic (fitness) time constant in days; Banister's default is 42")
            .accessibilityLabel("Fitness time constant in days")
            Stepper(
                "Fatigue \(Int(atlTimeConstantDays)) days",
                value: $atlTimeConstantDays,
                in: 3...30,
                step: 1
            )
            .frame(maxWidth: 180)
            .help("Acute (fatigue) time constant in days; Banister's default is 7")
            .accessibilityLabel("Fatigue time constant in days")
            Toggle("Include estimated loads", isOn: $includeEstimatedLoads)
                .help("Mostly running without a strap? Estimated loads can join the model, but they are invented values and bias the curve downward.")
                .accessibilityLabel("Include estimated loads in the model")
            Spacer()
        }
    }

    private func dayIndex(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Int? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        guard x >= 0, let instant: Date = proxy.value(atX: x) else { return nil }
        var nearest = 0
        for index in series.loadDays.indices where
            abs(series.loadDays[index].date.timeIntervalSince(instant))
                < abs(series.loadDays[nearest].date.timeIntervalSince(instant)) {
            nearest = index
        }
        return nearest
    }
}

/// Audio-graph descriptor for the training-load chart: the fitness series on
/// the y axis with the spoken summary as the chart summary.
private struct TrainingLoadChartDescriptor: AXChartDescriptorRepresentable {
    let series: FitnessFatigueSeries
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let xScale = AXNumericDataAxisDescriptor(
            title: "Day",
            range: xRange,
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value)
                .formatted(.dateTime.month(.abbreviated).day())
        }
        let yScale = AXNumericDataAxisDescriptor(
            title: "Fitness (CTL)",
            range: yRange,
            gridlinePositions: []
        ) { value in
            String(Int(value))
        }
        let seriesDescriptor = AXDataSeriesDescriptor(
            name: "Fitness",
            isContinuous: true,
            dataPoints: series.modelDays.map { day in
                AXDataPoint(x: day.date.timeIntervalSince1970, y: day.ctl)
            }
        )
        return AXChartDescriptor(
            title: "Training load by day",
            summary: summary,
            xAxis: xScale,
            yAxis: yScale,
            series: [seriesDescriptor]
        )
    }

    private var xRange: ClosedRange<Double> {
        let stamps = series.modelDays.map(\.date.timeIntervalSince1970)
        guard let minimum = stamps.min(), let maximum = stamps.max(), minimum < maximum else {
            return 0...1
        }
        return minimum...maximum
    }

    private var yRange: ClosedRange<Double> {
        let values = series.modelDays.map(\.ctl) + series.modelDays.map(\.atl)
        guard let minimum = values.min(), let maximum = values.max(), minimum < maximum else {
            return 0...1
        }
        return minimum...maximum
    }
}

/// One Trends chart panel: title, chart, gap-aware series, tap navigation,
/// and a chart accessibility descriptor.
private struct TrendsChartPanel: View {
    let metric: TrendsMetric
    let points: [TrendsChartPoint]
    let color: Color
    let spokenSummary: String
    let onHoverPeriod: (WorkoutTrendsPeriodKey?) -> Void
    let onNavigate: (WorkoutTrendsPeriodKey) -> Void

    /// Contiguous non-nil runs; gaps between them are never bridged.
    private var contiguousSeries: [[TrendsChartPoint]] {
        TrendsChartPoint.gapSplitSeries(points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(metric.chartTitle) per period")
                    .font(AppDesign.Typography.sectionHeadline)
                Spacer()
            }
            if points.contains(where: { $0.value != nil }) {
                chart
            } else {
                Text("No \(metric.accessibilityUnit) data in this scope.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    .accessibilityElement(children: .combine)
            }
        }
        .padding(AppDesign.Spacing.large)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var chart: some View {
        Chart {
            ForEach(contiguousSeries.indices, id: \.self) { seriesIndex in
                ForEach(contiguousSeries[seriesIndex]) { point in
                    switch metric {
                    case .distance, .ascent:
                        BarMark(
                            x: .value("Period", point.periodStart, unit: unit),
                            y: .value(metric.chartTitle, point.value ?? 0)
                        )
                        .foregroundStyle(color)
                        .cornerRadius(2)
                    case .pace, .heartRate:
                        LineMark(
                            x: .value("Period", point.periodStart, unit: unit),
                            y: .value(metric.chartTitle, point.value ?? 0),
                            // Without a distinct series, Charts joins every
                            // LineMark in the chart into one line and draws
                            // straight through the gaps, however the points
                            // are grouped in the builder.
                            series: .value("Section", seriesIndex)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(
                            x: .value("Period", point.periodStart, unit: unit),
                            y: .value(metric.chartTitle, point.value ?? 0)
                        )
                        .foregroundStyle(color)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: strideUnit, count: 1)) { value in
                AxisValueLabel(format: axisFormat, centered: false)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let numeric = value.as(Double.self) {
                        Text(yAxisLabel(numeric))
                    }
                }
            }
        }
        .frame(minHeight: 160)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            onHoverPeriod(period(at: location, proxy: proxy, geometry: geometry))
                        case .ended:
                            onHoverPeriod(nil)
                        }
                    }
                    .onTapGesture { location in
                        if let key = period(at: location, proxy: proxy, geometry: geometry) {
                            onNavigate(key)
                        }
                    }
            }
        }
        .accessibilityLabel("\(metric.chartTitle) per period")
        .accessibilityValue(spokenSummary)
        .accessibilityChartDescriptor(
            TrendsChartDescriptor(metric: metric, points: points, summary: spokenSummary)
        )
    }

    private func period(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> WorkoutTrendsPeriodKey? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        let x = location.x - origin.x
        guard x >= 0, let instant: Date = proxy.value(atX: x) else { return nil }
        var nearest: TrendsChartPoint?
        for point in points where nearest == nil
            || abs(point.periodStart.timeIntervalSince(instant)) < abs(nearest!.periodStart.timeIntervalSince(instant)) {
            nearest = point
        }
        return nearest?.key
    }

    private var unit: Calendar.Component {
        switch periodKind {
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    private var periodKind: WorkoutTrendsPeriod {
        points.first?.key.kind ?? .month
    }

    private var strideUnit: Calendar.Component {
        periodKind == .week ? .month : (periodKind == .month ? .year : .year)
    }

    private var axisFormat: Date.FormatStyle {
        switch periodKind {
        case .week: return .dateTime.month(.abbreviated).day()
        case .month: return .dateTime.month(.abbreviated).year()
        case .year: return .dateTime.year()
        }
    }

    private func yAxisLabel(_ value: Double) -> String {
        switch metric {
        case .distance:
            return String(format: "%.0f", value)
        case .pace:
            let mins = Int(value) / 60
            let secs = Int(value) % 60
            return String(format: "%d:%02d", mins, secs)
        case .heartRate:
            return "\(Int(value))"
        case .ascent:
            return "\(Int(value))"
        }
    }
}

/// Audio-graph descriptor for one Trends chart: period starts on the x axis,
/// gap-split series, spoken summary as the chart summary.
private struct TrendsChartDescriptor: AXChartDescriptorRepresentable {
    let metric: TrendsMetric
    let points: [TrendsChartPoint]
    let summary: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let populated = points.filter { $0.value != nil }
        let xScale = AXNumericDataAxisDescriptor(
            title: "Period start",
            range: xRange,
            gridlinePositions: []
        ) { value in
            let date = Date(timeIntervalSince1970: value)
            return date.formatted(.dateTime.month(.abbreviated).year())
        }
        let yValues = populated.compactMap(\.value)
        let yMin = yValues.min() ?? 0
        let yMax = yValues.max() ?? 1
        let yScale = AXNumericDataAxisDescriptor(
            title: "\(metric.chartTitle) (\(metric.unit))",
            range: min(yMin, yMax)...max(yMin, yMax, yMin + 0.001),
            gridlinePositions: []
        ) { value in
            switch metric {
            case .pace:
                let mins = Int(value) / 60
                let secs = Int(value) % 60
                return String(format: "%d:%02d /km", mins, secs)
            case .heartRate:
                return "\(Int(value)) bpm"
            case .distance:
                return String(format: "%.1f km", value)
            case .ascent:
                return "\(Int(value)) m"
            }
        }

        let series = TrendsChartPoint.gapSplitSeries(points)
        let dataSeries = series.enumerated().map { index, group in
            AXDataSeriesDescriptor(
                name: series.count == 1
                    ? "\(metric.chartTitle)"
                    : "\(metric.chartTitle), section \(index + 1)",
                isContinuous: metric == .distance || metric == .ascent,
                dataPoints: group.map {
                    AXDataPoint(
                        x: $0.periodStart.timeIntervalSince1970,
                        y: $0.value ?? 0
                    )
                }
            )
        }
        return AXChartDescriptor(
            title: "\(metric.chartTitle) per period",
            summary: summary,
            xAxis: xScale,
            yAxis: yScale,
            additionalAxes: [],
            series: dataSeries
        )
    }

    private var xRange: ClosedRange<Double> {
        let starts = points.map { $0.periodStart.timeIntervalSince1970 }
        guard let first = starts.min(), let last = starts.max(), last > first else {
            return 0...1
        }
        return first...last
    }
}
