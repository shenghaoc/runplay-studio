# Requirements: Map-Aware Light/Dark PNG Summary Export

## Problem

The PNG summary card is metrics-only, uses ambient window appearance, and
rasterizes with the main display’s backing scale. Runners need a configurable
export that includes a static Apple Maps region, optional metric route coloring,
and an explicit Light or Dark appearance at a fixed 1200×1600 pixel size.

## Requirements

1. Export Summary Card (PNG) SHALL open a configuration sheet with Include Map,
   Appearance (Light/Dark), Route Color, live preview, Cancel, and Export PNG.
2. Output PNG SHALL be exactly 1200×1600 pixels with explicit rasterization
   scale 1.0, independent of `NSScreen` or display backing scale.
3. Appearance SHALL resolve to concrete Light or Dark before rendering and SHALL
   not change mid-export. Colors SHALL use deterministic export palettes, never
   ambient `windowBackgroundColor`.
4. When Include Map is on and a usable route exists, the card SHALL include a
   static top-down Apple Maps basemap composited with route lines, start/finish
   markers, and (for metric modes) the canonical route-color legend. Replay
   markers MUST NOT appear.
5. Route coloring SHALL reuse PR #56 builders, palettes, availability, no-data
   style, and legend semantics. Export MUST NOT recalculate metrics or bridge
   route gaps. Unavailable modes SHALL be disabled or explained.
6. Metrics-only export SHALL remain available (no route, map failure, user off,
   or deliberate metrics card). Map failure SHALL offer Retry and Export Without
   Map; never a blank map.
7. Map imagery SHALL come from a Platform `MKMapSnapshotter` service with manual
   overlay composition. No screen/window capture. No Screen Recording permission.
8. Map-inclusive layout SHALL compact segments/splits (e.g. 3 / 5) and update the
   privacy footer to state local analysis plus Apple Maps imagery without
   claiming zero network use when a map was requested.
9. Generation SHALL be async and cancellable with progress phases; stale previews
   MUST NOT publish. Save SHALL reuse the last ready image when configuration is
   unchanged.
10. In-memory map cache keys SHALL include workout revision, color mode, palette
    version, appearance, dimensions, and planner version. Map imagery MUST NOT be
    persisted.

## Non-goals

- Video, heatmap, comparison-map, standalone route PNG, PDF, web sharing, cloud.
- Custom card dimensions/themes beyond Light/Dark, reverse geocoding, AI.
