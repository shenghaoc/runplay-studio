import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Displays both comparison routes on one Apple Maps surface with a native 2D/3D toggle.
struct ComparisonMapView: View {
    let primaryWorkout: RunWorkout
    let comparisonWorkout: RunWorkout
    let warnings: [ComparisonWarning]
    @ObservedObject var appState: AppState

    @State private var displayMode: RouteMapDisplayMode = .twoD
    @State private var fitRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var commonDistance: Double {
        appState.comparisonCommonDistanceMeters
    }

    private var comparisonSummary: ComparisonAccessibilitySummary {
        let metrics = appState.comparisonDistanceMetrics
        return ComparisonAccessibilitySummary(
            primaryName: primaryWorkout.displayName,
            comparisonName: comparisonWorkout.displayName,
            commonDistanceMeters: commonDistance,
            selectedDistanceMeters: appState.clampedComparisonDistanceMeters,
            primaryTimeLabel: metrics.primaryElapsedFormatted,
            comparisonTimeLabel: metrics.comparisonElapsedFormatted,
            deltaLabel: metrics.elapsedTimeDeltaFormatted,
            warnings: warnings.map(\.rawValue)
        )
    }

    private var routes: [RouteMapLine] {
        RouteMapContent.segmentedRoutes(
            idPrefix: "primary",
            points: primaryWorkout.routePoints,
            style: .primary
        ) + RouteMapContent.segmentedRoutes(
            idPrefix: "comparison",
            points: comparisonWorkout.routePoints,
            style: .comparison
        )
    }

    private var markers: [RouteMapMarker] {
        var markers = RouteMapContent.endpointMarkers(
            points: primaryWorkout.routePoints,
            idPrefix: "primary",
            startTitle: "Primary Start",
            finishTitle: "Primary Finish"
        )
        markers += RouteMapContent.endpointMarkers(
            points: comparisonWorkout.routePoints,
            idPrefix: "comparison",
            startTitle: "Comp. Start",
            finishTitle: "Comp. Finish"
        )

        let distance = appState.clampedComparisonDistanceMeters
        if distance > 0 {
            if let marker = RouteMapContent.marker(
                points: primaryWorkout.routePoints,
                distance: distance,
                id: "primary-current",
                title: "Primary at selected distance",
                style: .primaryCurrent
            ) {
                markers.append(marker)
            }
            if let marker = RouteMapContent.marker(
                points: comparisonWorkout.routePoints,
                distance: distance,
                id: "comparison-current",
                title: "Comparison at selected distance",
                style: .comparisonCurrent
            ) {
                markers.append(marker)
            }
        }
        return markers
    }

    var body: some View {
        ZStack {
            RouteMapCanvas(
                displayMode: $displayMode,
                routes: routes,
                markers: markers,
                fitRequest: fitRequest,
                controlBottomInset: 168,
                animateCamera: !reduceMotion
            )
            .accessibilityLabel("Comparison route map")
            .accessibilityValue(comparisonSummary.spokenSummary)

            VStack {
                HStack(alignment: .top) {
                    comparisonLegend
                    Spacer()
                    if !warnings.isEmpty {
                        comparisonWarnings
                    }
                    Spacer()
                    Button {
                        fitRequest += 1
                    } label: {
                        Label("Fit Routes", systemImage: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .help("Zoom and center the map to show both routes")
                    .accessibilityLabel("Fit Routes")
                }

                Spacer()
                distanceSliderBar
            }
            .padding()
        }
        .focusedSceneValue(\.mapActions, MapActions(
            isAvailable: { true },
            fit: { fitRequest += 1 },
            togglePresentation: {
                displayMode = displayMode == .threeD ? .twoD : .threeD
            },
            canTogglePresentation: { true }
        ))
        .onAppear {
            appState.clampComparisonDistance()
        }
    }

    private var comparisonLegend: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            MapModeBadge(displayMode: displayMode)
            legendRow(
                color: AppDesign.primaryBlue,
                symbol: "P",
                label: "Primary: \(primaryWorkout.displayName)"
            )
            legendRow(
                color: AppDesign.comparisonOrange,
                symbol: "C",
                label: "Comparison: \(comparisonWorkout.displayName)"
            )

            Divider()

            HStack(spacing: AppDesign.Spacing.small) {
                Circle().fill(AppDesign.energeticGreen).frame(width: 6, height: 6)
                Text("Start")
                    .font(AppDesign.Typography.compactLabel)
            }
            HStack(spacing: AppDesign.Spacing.small) {
                Circle().fill(AppDesign.alertRed).frame(width: 6, height: 6)
                Text("Finish")
                    .font(AppDesign.Typography.compactLabel)
            }

            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityLabel("Comparison summary")
                .accessibilityValue(comparisonSummary.spokenSummary)
        }
        .font(AppDesign.Typography.compactMetric)
        .padding(AppDesign.Spacing.medium)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
        .accessibilityElement(children: .combine)
    }

    private func legendRow(color: Color, symbol: String, label: String) -> some View {
        HStack(spacing: AppDesign.Spacing.small) {
            if differentiateWithoutColor {
                Text(symbol)
                    .font(AppDesign.Typography.compactLabel.weight(.bold))
                    .foregroundStyle(color)
                    .frame(width: 16, alignment: .center)
                    .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 16, height: 3)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var comparisonWarnings: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning.rawValue, systemImage: warning.icon)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(AppDesign.comparisonOrange)
            }
        }
        .padding(AppDesign.Spacing.medium)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
    }

    private var distanceSliderBar: some View {
        VStack(spacing: AppDesign.Spacing.small) {
            HStack {
                Text("Distance Along Route")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(appState.comparisonDistanceMetrics.selectedDistanceFormatted)
                    .font(AppDesign.Typography.compactMetric.monospacedDigit())
                if commonDistance > 0 {
                    Text("/ \(String(format: "%.2f km", commonDistance / 1000))")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: AppDesign.Spacing.small) {
                Button {
                    appState.selectedComparisonDistanceMeters = 0
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.body)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Jump to start (0 km)")
                .accessibilityLabel("Jump to start")
                .disabled(commonDistance <= 0)

                Slider(
                    value: $appState.selectedComparisonDistanceMeters,
                    in: 0...max(commonDistance, 1),
                    step: max(commonDistance / 500, 1)
                )
                .tint(AppDesign.comparisonOrange)
                .accessibilityLabel("Distance along route")
                .accessibilityValue(DisplayFormatter.formatDistanceKm(appState.clampedComparisonDistanceMeters))
                .disabled(commonDistance <= 0)

                Button {
                    appState.selectedComparisonDistanceMeters = commonDistance
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.body)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Jump to end (\(DisplayFormatter.formatDistanceKm(commonDistance)))")
                .accessibilityLabel("Jump to end")
                .accessibilityValue(DisplayFormatter.formatDistanceKm(commonDistance))
                .disabled(commonDistance <= 0)
            }

            comparisonDistanceMetricsRow
        }
        .padding(AppDesign.Spacing.medium)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
    }

    private var comparisonDistanceMetricsRow: some View {
        let metrics = appState.comparisonDistanceMetrics
        return Grid(horizontalSpacing: AppDesign.Spacing.large, verticalSpacing: AppDesign.Spacing.xSmall) {
            GridRow {
                Text("")
                Text("Selected")
                Text("Comparison")
                Text("Delta")
            }
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.tertiary)

            GridRow {
                metricLabel("Elapsed")
                metricValue(metrics.primaryElapsedFormatted, color: AppDesign.primaryBlue)
                metricValue(metrics.comparisonElapsedFormatted, color: AppDesign.comparisonOrange)
                metricValue(metrics.elapsedTimeDeltaFormatted, color: deltaColor(metrics.elapsedTimeDeltaSeconds))
            }

            GridRow {
                metricLabel("Active")
                metricValue(metrics.primaryActiveFormatted, color: AppDesign.primaryBlue)
                metricValue(metrics.comparisonActiveFormatted, color: AppDesign.comparisonOrange)
                metricValue(metrics.activeTimeDeltaFormatted, color: deltaColor(metrics.activeTimeDeltaSeconds))
            }

            GridRow {
                metricLabel("Moving (est.)")
                metricValue(metrics.primaryMovingFormatted, color: AppDesign.primaryBlue)
                metricValue(metrics.comparisonMovingFormatted, color: AppDesign.comparisonOrange)
                metricValue(metrics.movingTimeDeltaFormatted, color: deltaColor(metrics.movingTimeDeltaSeconds))
            }

            GridRow {
                metricLabel("Stopped (est.)")
                metricValue(metrics.primaryStoppedFormatted, color: AppDesign.primaryBlue)
                metricValue(metrics.comparisonStoppedFormatted, color: AppDesign.comparisonOrange)
                metricValue(metrics.stoppedTimeDeltaFormatted, color: deltaColor(metrics.stoppedTimeDeltaSeconds))
            }

            GridRow {
                metricLabel("Active Pace")
                metricValue(metrics.primaryPaceFormatted, color: AppDesign.primaryBlue)
                metricValue(metrics.comparisonPaceFormatted, color: AppDesign.comparisonOrange)
                metricValue(metrics.paceDeltaFormatted, color: deltaColor(metrics.paceDeltaSecondsPerKm))
            }
        }
        .help("Elapsed includes pauses. Active excludes recording gaps. Moving and stopped time are estimates.")
    }

    private func metricLabel(_ label: String) -> some View {
        Text(label)
            .font(AppDesign.Typography.compactLabel)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricValue(_ value: String, color: Color) -> some View {
        Text(value)
            .font(AppDesign.Typography.compactMetric.monospacedDigit())
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func deltaColor(_ delta: Double?) -> Color {
        AppDesign.deltaColor(delta)
    }
}
