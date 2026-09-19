import Accessibility
import Charts
import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Detail for one route group: run count and pace summary, the
/// representative-route map overlay, the active-pace-over-date progression
/// chart, and the member list with direction markers and manual controls.
struct RouteGroupDetailView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: RouteGroupsViewModel
    let groupID: UUID
    var onRename: (RouteGroupRow) -> Void

    @State private var mapDisplayMode: RouteMapDisplayMode = .twoD

    private var row: RouteGroupRow? {
        viewModel.rows.first { $0.id == groupID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xLarge) {
                if let row {
                    titleSection(row)
                    statsRow(row)
                    mapSection
                    progressionSection
                    memberSection
                } else {
                    Text("This route no longer exists. Re-cluster or pick another route.")
                        .font(AppDesign.Typography.metricLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(AppDesign.Spacing.xLarge)
        }
        .frame(minWidth: 420, maxHeight: .infinity)
    }

    // MARK: - Title

    private func titleSection(_ row: RouteGroupRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text(row.displayName)
                    .font(AppDesign.Typography.display)
                Text(summaryLine(row))
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onRename(row)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .help("Rename this route")
            .accessibilityLabel("Rename \(row.displayName)")
        }
        .accessibilityElement(children: .contain)
    }

    private func summaryLine(_ row: RouteGroupRow) -> String {
        var parts: [String] = []
        parts.append(String(
            format: String(localized: "route_group.detail.runs", defaultValue: "%d runs"),
            row.runCount
        ))
        if let last = row.lastRunDate {
            parts.append(String(
                format: String(localized: "route_group.detail.last", defaultValue: "last %@"),
                last.formatted(date: .abbreviated, time: .omitted)
            ))
        }
        parts.append(DisplayFormatter.formatDistance(row.representativeDistanceMeters))
        return parts.joined(separator: " · ")
    }

    // MARK: - Stats

    private func statsRow(_ row: RouteGroupRow) -> some View {
        HStack(spacing: AppDesign.Spacing.large) {
            paceStat(
                title: String(localized: "route_group.stat.best", defaultValue: "Best Pace"),
                value: row.bestPaceSecondsPerKilometer
            )
            paceStat(
                title: String(localized: "route_group.stat.median", defaultValue: "Median Pace"),
                value: row.medianPaceSecondsPerKilometer
            )
            paceStat(
                title: String(localized: "route_group.stat.latest", defaultValue: "Latest Pace"),
                value: row.latestPaceSecondsPerKilometer
            )
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func paceStat(title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
            Text(title)
                .font(AppDesign.Typography.metricLabel)
                .foregroundStyle(.tertiary)
            Text(DisplayFormatter.formatPace(value))
                .font(AppDesign.Typography.metricValue)
                .monospacedDigit()
                .foregroundStyle(AppDesign.MetricColor.pace)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(DisplayFormatter.formatPace(value) )")
    }

    // MARK: - Map

    @ViewBuilder
    private var mapSection: some View {
        if let representative = viewModel.representativeWorkout(for: groupID) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
                Text("Representative Route")
                    .font(AppDesign.Typography.sectionHeadline)
                MapReferenceView(
                    routePoints: representative.routePoints,
                    showAnnotations: true,
                    displayMode: $mapDisplayMode
                )
                .frame(height: 320)
                .panelBackground()
                .accessibilityLabel("Representative route map")
                .accessibilityValue(String(
                    format: String(localized: "route_group.map.ax", defaultValue: "Route overlay for %@, %.1f kilometres"),
                    representative.displayName,
                    max(0, representative.summary.totalDistanceMeters) / 1_000
                ))
            }
        }
    }

    // MARK: - Progression chart

    private var progressionSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Active Pace over Date")
                .font(AppDesign.Typography.sectionHeadline)
            if viewModel.progressionPoints.count >= 2 {
                RouteProgressionChart(points: viewModel.progressionPoints)
                    .frame(height: 220)
                    .panelBackground()
            } else {
                Text("At least two runs with an active pace are needed for a progression.")
                    .font(AppDesign.Typography.metricLabel)
                    .foregroundStyle(.secondary)
                    .padding(AppDesign.Spacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelBackground()
            }
        }
    }

    // MARK: - Members

    private var memberSection: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.medium) {
            Text("Runs on this Route")
                .font(AppDesign.Typography.sectionHeadline)
            Table(viewModel.memberRows) {
                TableColumn("Date") { member in
                    Text(member.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        .monospacedDigit()
                }
                .width(min: 140)
                TableColumn("Run") { member in
                    HStack(spacing: AppDesign.Spacing.small) {
                        Text(member.workoutName)
                        if member.isRepresentative {
                            Text("Representative")
                                .font(AppDesign.Typography.compactLabel)
                                .foregroundStyle(AppDesign.energeticGreen)
                        }
                        if member.isReversed {
                            Text("Reversed")
                                .font(AppDesign.Typography.compactLabel)
                                .foregroundStyle(AppDesign.comparisonOrange)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(memberAccessibilityLabel(member))
                }
                TableColumn("Active Pace") { member in
                    Text(DisplayFormatter.formatPace(member.paceSecondsPerKilometer))
                        .monospacedDigit()
                }
                .width(min: 90)
            }
            .contextMenu(forSelectionType: UUID.self) { selection in
                if let id = selection.first, let member = viewModel.memberRows.first(where: { $0.id == id }) {
                    Button {
                        Task {
                            await appState.pinRouteGroupRepresentative(groupID: groupID, workoutID: member.id)
                        }
                    } label: {
                        Label("Pin as Representative", systemImage: "pin")
                    }
                    .disabled(member.isRepresentative)
                    .accessibilityHint("Draw this run's route as the route overlay")

                    Button(role: .destructive) {
                        Task {
                            await appState.removeWorkoutFromRouteGroup(workoutID: member.id)
                        }
                    } label: {
                        Label("Remove from Route", systemImage: "minus.circle")
                    }
                    .accessibilityHint("Keep the run in the library but off this route")

                    Divider()

                    Button {
                        if let workout = appState.workouts.first(where: { $0.id == member.id }) {
                            appState.openWorkoutFromLibrary(workout)
                        }
                    } label: {
                        Label("Open Run", systemImage: "arrow.right.circle")
                    }
                }
            } primaryAction: { selection in
                if let id = selection.first,
                   let workout = appState.workouts.first(where: { $0.id == id }) {
                    appState.openWorkoutFromLibrary(workout)
                }
            }
            .frame(minHeight: 160)
        }
    }

    private func memberAccessibilityLabel(_ member: RouteGroupMemberRow) -> String {
        var parts: [String] = [member.workoutName]
        if let date = member.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(DisplayFormatter.formatPace(member.paceSecondsPerKilometer))
        if member.isRepresentative {
            parts.append(String(localized: "route_group.member.representative.ax", defaultValue: "representative"))
        }
        if member.isReversed {
            parts.append(String(localized: "route_group.member.reversed.ax", defaultValue: "run in the opposite direction"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Active-pace-over-date line chart with a VoiceOver chart descriptor.
struct RouteProgressionChart: View {
    let points: [RouteGroupProgressionPoint]

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Active Pace", point.paceSecondsPerKilometer)
            )
            .foregroundStyle(AppDesign.MetricColor.pace)
            .symbol(Circle())
            PointMark(
                x: .value("Date", point.date),
                y: .value("Active Pace", point.paceSecondsPerKilometer)
            )
            .foregroundStyle(AppDesign.MetricColor.pace)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).year())
                    .font(AppDesign.Typography.compactLabel)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let pace = value.as(Double.self) {
                        Text(DisplayFormatter.formatPaceShort(pace))
                            .font(AppDesign.Typography.compactLabel)
                            .monospacedDigit()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active pace progression")
        .accessibilityValue(spokenSummary)
        .accessibilityChartDescriptor(RouteProgressionChartDescriptor(points: points))
    }

    private var spokenSummary: String {
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return String(localized: "route_group.chart.empty.ax", defaultValue: "Not enough runs for a progression")
        }
        let count = points.count
        let best = points.map(\.paceSecondsPerKilometer).min() ?? 0
        return String(
            format: String(localized: "route_group.chart.summary.ax", defaultValue: "%d runs from %@ to %@, best active pace %@"),
            count,
            first.date.formatted(date: .abbreviated, time: .omitted),
            last.date.formatted(date: .abbreviated, time: .omitted),
            DisplayFormatter.formatPace(best)
        )
    }
}

/// VoiceOver chart descriptor for the route progression chart.
private struct RouteProgressionChartDescriptor: AXChartDescriptorRepresentable {
    let points: [RouteGroupProgressionPoint]

    func makeChartDescriptor() -> AXChartDescriptor {
        let times = points.map { $0.date.timeIntervalSince1970 }
        let paces = points.map(\.paceSecondsPerKilometer)
        let xScale = AXNumericDataAxisDescriptor(
            title: "Date",
            range: (times.min() ?? 0)...(times.max() ?? 1),
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .omitted)
        }
        let paceMin = paces.min() ?? 0
        let paceMax = paces.max() ?? 1
        let yScale = AXNumericDataAxisDescriptor(
            title: "Active pace (seconds per kilometre)",
            range: min(paceMin, paceMax)...max(paceMin, paceMax, paceMin + 0.001),
            gridlinePositions: []
        ) { value in
            DisplayFormatter.formatPaceShort(value)
        }
        let series = AXDataSeriesDescriptor(
            name: "Active Pace",
            isContinuous: true,
            dataPoints: points.map {
                AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.paceSecondsPerKilometer)
            }
        )
        return AXChartDescriptor(
            title: "Active pace over date",
            summary: nil,
            xAxis: xScale,
            yAxis: yScale,
            additionalAxes: [],
            series: [series]
        )
    }
}
