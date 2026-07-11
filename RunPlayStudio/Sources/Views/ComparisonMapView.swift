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

    private var commonDistance: Double {
        appState.comparisonCommonDistanceMeters
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
                controlBottomInset: 104
            )

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
                }

                Spacer()
                distanceSliderBar
            }
            .padding()
        }
        .onAppear {
            appState.clampComparisonDistance()
        }
    }

    private var comparisonLegend: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
            HStack(spacing: AppDesign.Spacing.xxSmall) {
                Circle()
                    .fill(displayMode == .threeD ? AppDesign.MetricColor.elevation : AppDesign.MetricColor.distance)
                    .frame(width: 5, height: 5)
                Text(displayMode == .threeD ? "3D" : "2D")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
            legendRow(color: AppDesign.primaryBlue, label: "Primary: \(primaryWorkout.displayName)")
            legendRow(color: AppDesign.comparisonOrange, label: "Comp.: \(comparisonWorkout.displayName)")

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
        }
        .font(.caption)
        .padding(AppDesign.Spacing.medium)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: AppDesign.Spacing.small) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 16, height: 3)
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .lineLimit(1)
        }
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
                        .font(.system(size: 10))
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
                        .font(.system(size: 10))
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
        return HStack(spacing: AppDesign.Spacing.large) {
            metricBadge(label: "Primary", value: metrics.primaryElapsedFormatted, color: AppDesign.primaryBlue)
            metricBadge(label: "Comp.", value: metrics.comparisonElapsedFormatted, color: AppDesign.comparisonOrange)
            metricBadge(label: "Δ Time", value: metrics.timeDeltaFormatted, color: deltaColor(metrics.timeDeltaSeconds))

            Divider().frame(height: 16)

            metricBadge(label: "Primary Pace", value: metrics.primaryPaceFormatted, color: AppDesign.primaryBlue)
            metricBadge(label: "Comp. Pace", value: metrics.comparisonPaceFormatted, color: AppDesign.comparisonOrange)
            metricBadge(label: "Δ Pace", value: metrics.paceDeltaFormatted, color: deltaColor(metrics.paceDeltaSecondsPerKm))
        }
        .frame(height: 24)
    }

    private func metricBadge(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(AppDesign.Typography.compactMetric.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        guard let delta, delta.isFinite, abs(delta) >= 0.5 else { return .secondary }
        return delta < 0 ? AppDesign.energeticGreen : AppDesign.alertRed
    }
}
