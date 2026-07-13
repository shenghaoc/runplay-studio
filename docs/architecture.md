# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → RoutePointSanitizer → Normalized Model → WorkoutTimeline → Analyzer → Workout Library
                                                                        ↘ Replay Controller → Views
                                                                        ↘ Comparison Service → Compare View
                                                     ↘ Route Coordinates → MapKit 2D/3D View
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: `RoutePointSanitizer` validates coordinates, preserves route-segment boundaries, and ensures cumulative distance does not include a recording gap
4. **Derive clocks**: `WorkoutTimeline` establishes elapsed, active, and paused time without mutating route timestamps
5. **Analyze**: `WorkoutAnalyzer` calculates pace, elevation, global-distance splits, and active-pace segments from that timeline
6. **Persist**: `FileWorkoutLibraryStore` atomically stores the normalized workout and versioned analysis snapshot
7. **Control**: `ReplayController` drives an elapsed-clock `PlaybackEngine`
8. **Render**: Views display a MapKit 2D/3D route map, charts, and summaries
9. **Compare**: `WorkoutComparisonService` compares elapsed, active, paused, and active-pace values by summary, split, and selected distance

## Module Structure

```
RunPlayCore/                   # Platform-neutral library (no UI frameworks)
├── Sources/
│   ├── Models/                # Data structures (RunWorkout, RoutePoint, etc.)
│   ├── Importers/             # File format parsers (JSON, GPX, TCX, FIT)
│   └── Services/              # Analysis, splits, segments, comparison, projection, export
└── Tests/
    └── RunPlayCoreTests/      # Platform-neutral tests

RunPlayPlatform/               # macOS non-UI layer (MapKit, SceneKit, AppKit values)
├── Sources/                   # Route/map data and rendering services
└── Tests/                     # Platform integration tests

RunPlayStudio/                 # macOS executable (SwiftUI, Swift Charts)
├── Sources/
│   ├── Services/              # UI-adjacent services (library loading, PNG export)
│   ├── ViewModels/            # View state management (AppState, ReplayController)
│   ├── Views/                 # SwiftUI views
│   └── 3D/                    # Legacy SceneKit prototype utilities (not the shipped map UI)
├── Resources/                 # Sample data and fixtures
└── Tests/
    └── RunPlayStudioTests/    # macOS-specific tests
```

## Key Abstractions

### WorkoutImporting Protocol

All importers conform to `WorkoutImporting`:

```swift
public protocol WorkoutImporting {
    var supportedExtensions: [String] { get }
    func importWorkout(from url: URL) throws -> RunWorkout
}
```

The `WorkoutImporterFactory` dispatches by file extension. The SwiftUI file picker allows generic data files so `.tcx` and `.fit` files remain selectable even when the system does not declare dedicated UTIs; unsupported extensions are rejected by the importer factory.

### FIT activity decoding

`FITParser` independently decodes the FIT binary stream into ordered standard
message values before `FITDecoder` interprets one running activity. The parser validates
header/file CRCs, definition architecture and field types, compressed timestamp
headers, invalid sentinels, and bounded resource use. It retains file-ID,
record, event, lap, session, activity, and device-info messages in source order.
`FITDecoder` selects one
unambiguous GPS-bearing running session, filters its records and timer events,
and assigns `routeSegmentIndex` values so normalization, analysis, replay, and
map rendering do not bridge pause/resume gaps. The implementation targets common
running activities from Garmin FIT SDK Profile 21.205.0; developer metrics and
other unsupported FIT profile features remain skipped rather than interpreted.
Selected-session `total_elapsed_time` and `total_timer_time` are validation
signals only. Route timestamps and timer-derived segment indexes remain the
cross-format source of truth. A difference greater than five seconds or two
percent of the route-derived value, whichever is larger, produces an import
warning without replacing the route result.

### WorkoutTimeline

`WorkoutTimeline` is the single platform-neutral semantic authority consumed by
`WorkoutAnalyzer`, `SplitCalculator`, `SegmentDetector`, `PlaybackEngine`,
`WorkoutComparisonService`, and export models.

- elapsed time is the final timestamp minus the first timestamp, falling back
  to normalized per-point elapsed values only when timestamps do not span;
- active time sums positive adjacent deltas within one route segment; the
  timestamp-free fallback treats elapsed time as active because it cannot infer
  pauses;
- paused time is elapsed minus active;
- distance sampling returns both clocks and never interpolates geography across
  a segment boundary;
- duplicate-distance range starts use the resumed point, while range ends use
  the pre-pause endpoint;
- replay lookup returns the latest real point whose elapsed time is at or before
  the replay clock.

Global kilometre splits and pace windows may span route segments because their
distance axis is cumulative. Primitive time, elevation, smoothing, and
coordinate interpolation remain segment-local, so no synthetic cross-gap
sample is created.

### Workout library persistence

`WorkoutLibraryStoring`, `FileWorkoutLibraryStore`, and
`WorkoutLibraryManifest` live in `RunPlayCore`. The store writes complete
normalized workout snapshots beneath Application Support using atomic writes.
`RunPlayStudio` supplies the production root URL and applies background load
results to `AppState`; bundled demos remain SwiftPM resources rather than user
library entries.

`RunWorkout.analysisVersion` versions derived analysis independently from the
manifest schema. During actor-isolated library loading, a stale workout is
reanalysed from its stored route, returned upgraded in memory, and atomically
rewritten. If the rewrite fails, the workout stays visible with a warning and
the legacy file remains intact for retry on the next launch. No manifest schema
bump is required.

### GeoDistance

Platform-neutral distance calculation using the Haversine formula, replacing CoreLocation:

```swift
public enum GeoDistance {
    static func distanceMeters(fromLat: Double, lon: Double, toLat: Double, lon: Double) -> Double
    static func isValidCoordinate(lat: Double, lon: Double) -> Bool
}
```

### RoutePointInterpolator

Distance-based interpolation helpers used for route coordinates and chart
metrics. Pause-aware clocks and split boundaries use `WorkoutTimeline` instead:

```swift
public enum RoutePointInterpolator {
    static func point(at distance: Double, in points: [RoutePoint]) -> RoutePoint?
    static func scenePoint(at distance: Double, in points: [RouteScenePoint]) -> RouteScenePoint?
    static func firstIndex(atOrAfter: Double, in: [RoutePoint]) -> Int?
    static func lastIndex(atOrBefore: Double, in: [RoutePoint]) -> Int?
    static func averageHeartRate(in: [RoutePoint], from: Double, to: Double) -> Double?
    static func elevationGain(in: [RoutePoint], from: Double, to: Double) -> Double?
}
```

### WorkoutComparisonService

Route comparison is intentionally distance-based for the MVP. It does not do
dynamic time warping or complex route matching.

```swift
public struct WorkoutComparisonService {
    public func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary
    public func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison]
    public func compareMetricsOverDistance(primary: RunWorkout, comparison: RunWorkout, sampleIntervalMeters: Double = 100) -> [ComparisonMetricPoint]
    public func commonDistance(primary: RunWorkout, comparison: RunWorkout) -> Double
    public func metricsAtDistance(_ distance: Double, primary: RunWorkout, comparison: RunWorkout, primaryScenePoints: [RouteScenePoint], comparisonScenePoints: [RouteScenePoint]) -> ComparisonDistanceMetrics
}
```

The service clamps metric series to the common distance, filters non-finite
metric values, handles missing heart-rate/elevation data, and returns warnings
instead of crashing on weak comparisons. Summary comparison distinguishes
elapsed, active, paused, active-pace, and elapsed-pace deltas. At selected
distance, `WorkoutTimeline` supplies elapsed and active time plus cumulative
active pace; route coordinates still use segment-local interpolation. Runs with
materially different pause durations receive an informative warning.

Replay remains on elapsed time, so its total duration equals summary elapsed
time. Inside a route gap the clock advances while the marker, distance, point
metrics, and active time remain at the stop endpoint. The resume point appears
only at its exact timestamp; no pause coordinates are synthesized.

### RouteMapCanvas

`RouteMapCanvas` is the shared SwiftUI MapKit surface for single-run and
comparison maps. It owns a `MapCameraPosition`, draws `MapPolyline` and
`Annotation` content, and exposes one 2D/3D camera toggle plus native MapKit
zoom controls. The 2D/3D state changes the same map camera:

- one realistic-elevation map style in both modes
- `MapCamera.pitch` of 0° versus a pitched perspective

`RouteMapContent` filters invalid coordinates, computes fitting bounds, and
interpolates selected-distance markers without introducing another renderer.

## Dependencies

### Apple Frameworks Used (macOS targets only)

- **SwiftUI**: App UI and views
- **MapKit**: Platform route/map data and one SwiftUI map with top-down and pitched presentations
- **Swift Charts**: Pace, elevation, heart rate charts
- **SceneKit**: Legacy prototype utilities retained internally; not the shipped map surface
- **UniformTypeIdentifiers**: File import
- **Foundation**: Parsing and models

### Platform-Neutral (RunPlayCore)

- **Foundation**: Parsing and models
- **FoundationXML**: XML parsing on Linux (conditional import)

### Third-Party Dependencies

**None** — MVP uses only Apple-native frameworks.

## Future Considerations

- AVFoundation for video export
- HealthKit for direct Apple Health import
- Moving-time estimation with an explicitly chosen speed threshold
