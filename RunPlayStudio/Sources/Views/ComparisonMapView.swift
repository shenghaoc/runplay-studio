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
        [
            RouteMapContent.route(
                id: "primary",
                points: primaryWorkout.routePoints,
                style: .primary
            ),
            RouteMapContent.route(
                id: "comparison",
                points: comparisonWorkout.routePoints,
                style: .comparison
            )
        ]
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
        VStack(alignment: .leading, spacing: 6) {
            Text(displayMode == .threeD ? "Apple Maps 3D" : "Apple Maps 2D")
                .font(.caption2)
                .foregroundStyle(.secondary)
            legendRow(color: .blue, label: "Primary: \(primaryWorkout.displayName)")
            legendRow(color: .orange, label: "Comp.: \(comparisonWorkout.displayName)")

            Divider()

            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Start")
            }
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Finish")
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 18, height: 4)
            Text(label).lineLimit(1)
        }
    }

    private var comparisonWarnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning.rawValue, systemImage: warning.icon)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var distanceSliderBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Distance Along Route")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(appState.comparisonDistanceMetrics.selectedDistanceFormatted)
                    .font(.caption.monospacedDigit())
                if commonDistance > 0 {
                    Text("/ \(String(format: "%.2f km", commonDistance / 1000))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    appState.selectedComparisonDistanceMeters = 0
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                .help("Jump to start (0 km)")

                Slider(
                    value: $appState.selectedComparisonDistanceMeters,
                    in: 0...max(commonDistance, 1),
                    step: max(commonDistance / 500, 1)
                )
                .disabled(commonDistance <= 0)

                Button {
                    appState.selectedComparisonDistanceMeters = commonDistance
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.plain)
                .help("Jump to end (\(String(format: "%.2f", commonDistance / 1000)) km)")
                .disabled(commonDistance <= 0)
            }

            comparisonDistanceMetricsRow
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var comparisonDistanceMetricsRow: some View {
        let metrics = appState.comparisonDistanceMetrics
        return HStack(spacing: 16) {
            metricBadge(label: "Primary", value: metrics.primaryElapsedFormatted, color: .blue)
            metricBadge(label: "Comp.", value: metrics.comparisonElapsedFormatted, color: .orange)
            metricBadge(label: "Δ Time", value: metrics.timeDeltaFormatted, color: deltaColor(metrics.timeDeltaSeconds))

            Divider().frame(height: 16)

            metricBadge(label: "Primary Pace", value: metrics.primaryPaceFormatted, color: .blue)
            metricBadge(label: "Comp. Pace", value: metrics.comparisonPaceFormatted, color: .orange)
            metricBadge(label: "Δ Pace", value: metrics.paceDeltaFormatted, color: deltaColor(metrics.paceDeltaSecondsPerKm))
        }
        .frame(height: 24)
    }

    private func metricBadge(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func deltaColor(_ delta: Double?) -> Color {
        guard let delta, delta.isFinite, abs(delta) >= 0.5 else { return .secondary }
        return delta < 0 ? .green : .red
    }
}
