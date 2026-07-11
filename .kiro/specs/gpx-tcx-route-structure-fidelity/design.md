# Design Document

## Overview

The feature adds `routeSegmentIndex` to `RoutePoint` and carries it into
`RouteScenePoint`. The importers assign source boundaries, while the sanitizer
compacts the valid indexes and maintains a cumulative distance that does not
include a geographic leap at a boundary. Consumers use the index to decide
whether adjacent points belong to one continuous route.

No new SwiftUI controls are introduced. Existing map, comparison, replay,
split, and highlight surfaces consume the same normalized workout model and
become gap-safe automatically.

## Components

### Importers and persistence

- `GPXImporter` parses `trk > trkseg > trkpt`; only track points are accepted.
- `TCXImporter` parses `Activity > Lap > Track > Trackpoint`, selects exactly
  one GPS-bearing activity, and rebases supplied distance inside each track.
- `RoutePoint` has custom Codable decoding so persisted snapshots created
  before this feature decode with segment index `0`.

### Core analysis

- `RoutePointSanitizer` orders points within each segment, compacts indexes, and
  computes distance only between points in the same segment.
- `WorkoutAnalyzer` sums elapsed deltas only within a segment for summary
  duration and average pace.
- `SplitCalculator` emits kilometer or partial splits per contiguous segment.
- `SegmentDetector`, interpolation, and metric smoothing reject or isolate
  boundary-spanning calculations.

### Rendering

- `RouteMapContent.segmentedRoutes` creates one map polyline per segment.
- Projection services preserve the segment index for legacy 3D utilities.
- `RouteSceneBuilder` and `ComparisonSceneBuilder` skip cross-segment tubes;
  selected highlights use the same guard.

## Verification Strategy

- Importer tests cover GPX/TCX segment indexes, waypoint exclusion, supplied
  distance rebasing, discontinuity distance handling, and ambiguous TCX files.
- Analysis tests cover summary duration, splits, and elevation detection over a
  synthetic segment gap.
- Scene tests count highlight tubes to prove a selected highlight does not
  bridge a discontinuity.
- SwiftPM, Xcode macOS tests, and packaged-app launch verification provide the
  final gate evidence.
