# Requirements: Native Route Metric Coloring

## Problem

The native Apple Maps single-workout path paints each route segment with one
primary color. Pace, heart-rate, and elevation coloring exist only on the
legacy SceneKit path (`RouteScenePoint` / `NSColor`) and invent missing values
with medians. Runners need relative metric coloring on the shipped MapKit
surface without a second renderer.

## Requirements

1. The single-workout native map SHALL support Solid, Pace, Heart Rate, and
   Corrected Elevation route-color modes with an explicit relative-to-this-workout
   scale. Comparison maps remain blue/orange; heatmap density palettes remain
   unchanged.
2. `RunPlayCore` SHALL own a single `RouteMetricProfileBuilder` that emits
   palette-independent intervals, distance-weighted scales, and bucket tokens.
   Core MUST NOT import AppKit, SwiftUI, MapKit, SceneKit, or CoreLocation.
3. Pace SHALL use active-time semantics from `WorkoutTimeline` and validated
   cumulative distance. Missing/invalid intervals remain nil (no median fill).
   Intervals MUST NOT cross route segment boundaries.
4. Heart rate SHALL use shared `MetricValidation` ranges, preserve missing
   sections as no-data, and report distance coverage. No personalized zones.
5. Elevation SHALL use `WorkoutAnalysisContext.elevationProfile` corrected
   altitudes only — never raw `RoutePoint.altitudeMeters` or SceneKit Y.
6. Platform SHALL coalesce metric intervals into bounded `RouteMapLine`s with
   shared boundary coordinates, short-run hysteresis, and adaptive chunking
   under a central maximum line budget (default 1,000).
7. Studio SHALL provide a Route Color control, accessible legend with numeric
   labels, no-data indicator, coverage help, `@AppStorage` preference, and
   off-main-actor cancellable builds that do not rebuild on replay ticks.
8. Legacy `RouteColorMetrics` / `RouteColoringService` SHALL delegate metric
   semantics to the new builder so SceneKit and MapKit share one source of truth.
9. The feature is local-only presentation state: no workout migration, analysis
   version bump, export changes, cloud, or telemetry.

## Non-goals

- Metric-colored comparison routes or personalized HR zones.
- Grade-adjusted pace, map matching, street snapping, custom palettes.
- Route-map / heatmap export, broad SceneKit deletion, AI features.
