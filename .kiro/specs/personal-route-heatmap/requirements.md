# Requirements: Personal Route Heatmap

## Problem

RunPlay Studio needs a local, useful way to see where its existing workout
library overlaps without treating GPS sample density as repeat visits or
creating an invented route across a recording gap.

## Requirements

1. The app SHALL provide a discoverable Personal Heatmap workspace from the
   Library sidebar and Workout menu, while keeping workout, comparison, and
   heatmap workspaces mutually exclusive.
2. `RunPlayCore` SHALL aggregate distinct workouts per projected grid cell.
   Loops and dense samples within one workout SHALL contribute at most once;
   valid one-point and gap endpoints SHALL remain visible.
3. Heatmap traversal SHALL never bridge source route boundaries, inferred gaps,
   or discarded invalid coordinates. Intervals over the configured maximum
   length SHALL not create a corridor.
4. Users SHALL be able to choose date filters, 25/50/100 metre resolution, and
   a minimum-repeat count. All Time includes routed workouts without metadata
   dates; date-limited modes exclude workouts without a trustworthy date.
5. The rendered result SHALL remain usable for large local libraries. The
   builder SHALL adaptively coarsen a projected metric grid instead of randomly
   dropping cells, and report the effective resolution.
6. Aggregation SHALL run off the main actor, be cancellable, suppress stale
   results, and cache matching in-memory requests. Clock changes SHALL not
   invalidate All Time or Custom requests; a cache hit SHALL cancel a
   superseded build.
7. The map SHALL use the existing native SwiftUI Map/MapKit path with filled
   areas, an accessible legend, controls, empty/loading/error states, and a
   Fit Heatmap action. It SHALL not duplicate the existing map renderer.
8. Heatmap data SHALL remain local and derived: no upload, geocoding,
   telemetry, persistent heatmap database, analysis-version bump, or manifest
   schema change.

## Non-goals

- Heatmap export, per-cell workout drill-down, routing or map matching.
- Cloud/social sharing, accounts, HealthKit, or third-party heatmap services.
- A custom map renderer or changes to existing single-route/comparison maps.
