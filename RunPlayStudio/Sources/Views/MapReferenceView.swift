import RunPlayCore
import RunPlayPlatform
import SwiftUI

/// Displays a route on one Apple Maps surface with an in-map 2D/3D control
/// and optional metric route coloring for the single-workout map.
///
/// Comparison and heatmap maps use other views and must not pass a metric
/// view model here.
struct MapReferenceView: View {
    let routePoints: [RoutePoint]
    var currentPointIndex: Int = 0
    var showAnnotations: Bool = true
    /// When non-nil, drives metric route coloring. Solid primary color otherwise.
    var mapViewModel: WorkoutRouteMapViewModel?

    @AppStorage("routeColorMode") private var storedColorModeRaw: String = WorkoutRouteColorMode.solid.rawValue
    @State private var displayMode: RouteMapDisplayMode = .twoD
    @State private var fitRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var preferredMode: WorkoutRouteColorMode {
        WorkoutRouteColorMode(rawValue: storedColorModeRaw) ?? .solid
    }

    private var routes: [RouteMapLine] {
        if let presentation = mapViewModel?.presentation, !presentation.lines.isEmpty {
            return presentation.lines
        }
        return RouteMapContent.segmentedRoutes(idPrefix: "route", points: routePoints, style: .primary)
    }

    private var markers: [RouteMapMarker] {
        guard showAnnotations else { return [] }
        var markers = RouteMapContent.endpointMarkers(points: routePoints, idPrefix: "route")
        if let current = RouteMapContent.currentMarker(points: routePoints, index: currentPointIndex) {
            markers.append(current)
        }
        return markers
    }

    var body: some View {
        RouteMapCanvas(
            displayMode: $displayMode,
            routes: routes,
            markers: markers,
            fitRequest: fitRequest,
            controlBottomInset: legendBottomInset
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                mapModeBadge
                if mapViewModel != nil {
                    routeColorControl
                }
            }
            .padding()
        }
        .overlay(alignment: .topTrailing) {
            Button {
                fitRequest += 1
            } label: {
                Label("Fit Route", systemImage: "viewfinder")
                    .font(AppDesign.Typography.compactMetric)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Zoom and center the map to show the full route")
            .padding()
        }
        .overlay(alignment: .bottomLeading) {
            if mapViewModel != nil {
                metricLegendOverlay
                    .padding()
                    .padding(.bottom, 4)
            }
        }
        .onAppear {
            syncPreferredMode()
        }
        .onChange(of: storedColorModeRaw) { _, _ in
            syncPreferredMode()
        }
    }

    private var legendBottomInset: CGFloat {
        guard mapViewModel != nil else { return 0 }
        if mapViewModel?.presentation?.effectiveMode == .solid || mapViewModel?.presentation?.effectiveMode == nil {
            return mapViewModel?.isBuilding == true ? 36 : 8
        }
        return 96
    }

    private var mapModeBadge: some View {
        MapModeBadge(displayMode: displayMode)
            .padding(.horizontal, AppDesign.Spacing.medium)
            .padding(.vertical, AppDesign.Spacing.small)
            .background(.regularMaterial)
            .clipShape(Capsule())
    }

    private var routeColorControl: some View {
        HStack(spacing: AppDesign.Spacing.small) {
            Menu {
                ForEach(WorkoutRouteColorMode.allCases, id: \.self) { mode in
                    let available = mapViewModel?.availability.isAvailable(mode) ?? (mode == .solid)
                    Button {
                        storedColorModeRaw = mode.rawValue
                        mapViewModel?.preferredMode = mode
                    } label: {
                        HStack {
                            Text(mode.displayName)
                            if preferredMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!available && mode != .solid)
                }
            } label: {
                Label(String(localized: "Route Color"), systemImage: "paintpalette")
                    .font(AppDesign.Typography.compactMetric)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, AppDesign.Spacing.medium)
            .padding(.vertical, AppDesign.Spacing.small)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .help(String(localized: "Color the route by solid, relative pace, heart rate, or corrected elevation"))
            .accessibilityLabel(String(localized: "Route Color"))
            .accessibilityValue(preferredMode.displayName)
            .accessibilityHint(String(localized: "Choose how the workout route is colored on the map"))

            if mapViewModel?.isBuilding == true {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Updating route colors"))
            }
        }
    }

    @ViewBuilder
    private var metricLegendOverlay: some View {
        if let presentation = mapViewModel?.presentation {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                if let reason = presentation.fallbackReason, presentation.effectiveMode == .solid {
                    Text(reason)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                        .padding(AppDesign.Spacing.small)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.small))
                        .accessibilityLabel(reason)
                }

                if presentation.effectiveMode != .solid,
                   let profile = presentation.profile,
                   let scale = profile.scale {
                    RouteMetricLegendView(
                        mode: presentation.effectiveMode,
                        scale: scale,
                        showsNoData: profile.diagnostics.noDataIntervalCount > 0,
                        coverageFraction: profile.validCoverageFraction
                    )
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation.effectiveMode)
        }
    }

    private func syncPreferredMode() {
        let mode = preferredMode
        if mapViewModel?.preferredMode != mode {
            mapViewModel?.preferredMode = mode
        }
    }
}

// MARK: - Legend

struct RouteMetricLegendView: View {
    let mode: WorkoutRouteColorMode
    let scale: RouteMetricScale
    var showsNoData: Bool = false
    var coverageFraction: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
            Text("\(mode.displayName) — \(mode.relativeScaleCaption)")
                .font(AppDesign.Typography.compactLabel.weight(.semibold))
                .foregroundStyle(.primary)

            // Gradient swatches
            HStack(spacing: 2) {
                ForEach(0..<RouteMetricPalette.policyBucketCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppDesign.RouteMetric.color(mode: mode, bucket: .level(index)))
                        .frame(height: 8)
                }
            }
            .frame(maxWidth: 220)
            .accessibilityHidden(true)

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(scale.lowerLabel)
                        .font(AppDesign.Typography.monoCaption)
                    Text(lowerEndLabel)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppDesign.Spacing.small)
                VStack(alignment: .center, spacing: 1) {
                    Text(scale.medianLabel)
                        .font(AppDesign.Typography.monoCaption)
                    Text(String(localized: "Median"))
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: AppDesign.Spacing.small)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(scale.upperLabel)
                        .font(AppDesign.Typography.monoCaption)
                    Text(upperEndLabel)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220)

            if showsNoData {
                HStack(spacing: AppDesign.Spacing.xSmall) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppDesign.RouteMetric.noData)
                        .frame(width: 14, height: 8)
                    Text(String(localized: "No data"))
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
            }

            if coverageFraction < 0.92, coverageFraction > 0 {
                Text(coverageText)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(AppDesign.Spacing.medium)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Radius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var lowerEndLabel: String {
        switch mode {
        case .pace: return String(localized: "Faster")
        case .heartRate: return String(localized: "Lower")
        case .correctedElevation: return String(localized: "Lower")
        case .solid: return ""
        }
    }

    private var upperEndLabel: String {
        switch mode {
        case .pace: return String(localized: "Slower")
        case .heartRate: return String(localized: "Higher")
        case .correctedElevation: return String(localized: "Higher")
        case .solid: return ""
        }
    }

    private var coverageText: String {
        let percent = Int((coverageFraction * 100).rounded())
        switch mode {
        case .heartRate:
            return String(localized: "Heart-rate data covers \(percent)% of route distance.")
        case .correctedElevation:
            return String(localized: "Corrected elevation covers \(percent)% of route distance.")
        case .pace:
            return String(localized: "Valid pace covers \(percent)% of route distance.")
        case .solid:
            return ""
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            "\(mode.displayName) legend. \(mode.relativeScaleCaption).",
            "\(lowerEndLabel) \(scale.lowerLabel).",
            "\(String(localized: "Median")) \(scale.medianLabel).",
            "\(upperEndLabel) \(scale.upperLabel)."
        ]
        if showsNoData {
            parts.append(String(localized: "Some sections have no metric data."))
        }
        if coverageFraction < 0.92, coverageFraction > 0 {
            parts.append(coverageText)
        }
        return parts.joined(separator: " ")
    }
}
