# Design: Personal Route Heatmap

## Layers

- **RunPlayCore** defines the `PersonalHeatmap*` value types and a deterministic
  Web Mercator square-grid builder. It validates mutable configuration, filters
  workouts once, rasterizes continuous intervals, counts each visited cell once
  per workout, and retries with doubled cell size until the render budget fits.
- **RunPlayPlatform** converts a snapshot into `RouteMapArea` values and extends
  the shared map-rect/camera planning path to include areas without adding a
  second map system.
- **RunPlayStudio** owns `PersonalHeatmapViewModel`, `AppWorkspaceMode`, native
  sidebar selection, menu commands, filters, status UI, and filled map display.

## Aggregation and continuity

The builder projects valid WGS84 points into metres and indexes `Int64` cells.
It gives every retained point an effective continuity segment. A source segment
change or any invalid/discarded source point starts a new effective segment.
Every valid point covers its own cell; line rasterization occurs only between
adjacent points in the same effective segment and rejects malformed long jumps.
The per-workout visited set is then folded into global distinct-workout counts.

Snapshots retain rendered cells, bounds, user-visible statistics, diagnostics,
and the effective configuration. Intensity is `log1p(cellCount) /
log1p(maximumCount)`. The minimum-repeat filter is applied after aggregation so
the maximum-overlap statistic preserves the full selected-library result.

## View-model lifecycle

The view model builds a key from the relevant workout revisions and selected
filters. Relative filters resolve one injected `now` rounded to the hour;
All Time and Custom use a stable sentinel because their result does not depend
on wall-clock time. Each refresh cancels the previous task and shared
cooperative cancel flag before either applying a cache hit or starting a
detached builder. Only the current key may publish a result.

`AppState` owns mutually exclusive workspace state. Selecting a workout exits
heatmap; entering comparison cancels heatmap; deletion keeps the heatmap open
and recomputes against the changed library. Existing route and comparison maps
continue to call `RouteMapCanvas` with no areas.

The Workout menu first uses its focused-scene action. When native menu focus
temporarily clears that value, it emits an app-local workspace command that the
root content view routes to the same `AppState` method, keeping the menu item
and shortcut available without duplicating navigation logic.

## Privacy and verification

The result is derived in memory and is never persisted. MapKit may load Apple
basemap tiles for the visible region under the existing MapKit privacy policy.
Focused Core, Platform, Studio, cache/cancellation, navigation, and warning-free
full package tests validate behavior. The manual checklist remains the source
of truth for interactive synthetic-workout and accessibility verification.
