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
    @Binding private var displayMode: RouteMapDisplayMode
    @State private var fitRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        routePoints: [RoutePoint],
        currentPointIndex: Int = 0,
        showAnnotations: Bool = true,
        mapViewModel: WorkoutRouteMapViewModel? = nil,
        displayMode: Binding<RouteMapDisplayMode> = .constant(.twoD)
    ) {
        self.routePoints = routePoints
        self.currentPointIndex = currentPointIndex
        self.showAnnotations = showAnnotations
        self.mapViewModel = mapViewModel
        self._displayMode = displayMode
    }

    private var currentDistanceMeters: Double? {
        guard routePoints.indices.contains(currentPointIndex) else { return nil }
        return routePoints[currentPointIndex].distanceFromStartMeters
    }

    private var routeSummary: RouteAccessibilitySummary {
        let presentation = mapViewModel?.presentation
        let modeName = presentation?.effectiveMode.displayName ?? preferredMode.displayName
        let coverage = presentation?.profile?.validCoverageFraction
        return RouteAccessibilitySummary.make(
            routePoints: routePoints,
            currentDistanceMeters: currentDistanceMeters,
            colorModeName: modeName,
            coverageFraction: coverage
        )
    }

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
            controlBottomInset: legendBottomInset,
            animateCamera: !reduceMotion
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workout route map")
        .accessibilityValue(routeSummary.spokenSummary)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                mapModeBadge
                if mapViewModel != nil {
                    routeColorControl
                }
                // Nonvisual route summary for VoiceOver (not a second map surface).
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityLabel("Route summary")
                    .accessibilityValue(routeSummary.spokenSummary)
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
            .accessibilityLabel("Fit Route")
            .accessibilityHint("Zooms and centers the map on the full route")
            .padding()
        }
        .overlay(alignment: .bottomLeading) {
            if mapViewModel != nil {
                metricLegendOverlay
                    .padding()
                    .padding(.bottom, 4)
            }
        }
        .focusedSceneValue(\.mapActions, MapActions(
            isAvailable: { !routePoints.isEmpty },
            fit: { fitRequest += 1 },
            togglePresentation: {
                displayMode = displayMode == .threeD ? .twoD : .threeD
            },
            canTogglePresentation: { !routePoints.isEmpty }
        ))
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
                    let modeHelp = routeColorModeHelp(mode, available: available)
                    Button {
                        storedColorModeRaw = mode.rawValue
                        mapViewModel?.preferredMode = mode
                    } label: {
                        HStack {
                            if !available, mode != .solid {
                                Text("\(mode.displayName) — \(String(localized: "Unavailable"))")
                            } else {
                                Text(mode.displayName)
                            }
                            if preferredMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(!available && mode != .solid)
                    .help(modeHelp)
                    .accessibilityHint(modeHelp)
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

    private func routeColorModeHelp(_ mode: WorkoutRouteColorMode, available: Bool) -> String {
        if !available, let reason = mode.unavailableReason {
            return reason
        }
        switch mode {
        case .solid:
            return String(localized: "Show the route in the primary color.")
        case .pace:
            return String(localized: "Color the route by relative pace within this workout.")
        case .heartRate:
            return String(localized: "Color the route by relative heart rate within this workout.")
        case .correctedElevation:
            return String(localized: "Color the route by corrected elevation within this workout.")
        }
    }
}
