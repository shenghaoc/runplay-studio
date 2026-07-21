# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → RouteQualityProcessor → Normalized Route + Diagnostics
                                                ↓
                              WorkoutAnalysisContext
                              ├── WorkoutTimeline
                              └── ElevationProfile
                                        ↓
              Analyzer → Summary / Splits / Highlights → Workout Library
                 ├── Replay / Comparison / Exports
                 ├── Personal Heatmap (derived library-level aggregation)
                 └── Charts / Route Projection / Route Colouring
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: `RouteQualityProcessor` validates fields, removes only strong isolated coordinate outliers, infers supported recording gaps, normalizes distance, and records distance provenance and quality diagnostics
4. **Correct elevation**: `ElevationProfile` preserves source altitude on each `RoutePoint` while deriving an aligned, gap-safe corrected profile and threshold-confirmed ascent/descent
5. **Build context**: `WorkoutAnalysisContext` owns one immutable profile and a `WorkoutTimeline` built from that same profile
6. **Analyze**: `WorkoutAnalyzer` passes the context to summary, global-distance splits, source-recorded laps (`RecordedLapAnalyzer`), and notable-segment detection so every elevation consumer shares one correction
7. **Persist**: `FileWorkoutLibraryStore` atomically stores the normalized route, provenance, diagnostics, warnings, and versioned analysis snapshot
8. **Control**: `ReplayController` drives an elapsed-clock `PlaybackEngine` whose selected elevation comes from the corrected profile
9. **Render and export**: Charts, route projection/colouring, comparison, and exports consume corrected analysis while raw imported altitude remains source data

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

## Personal Heatmap

The Personal Heatmap is a **derived, library-level** visualization. It is not
stored on each `RunWorkout` and does not bump analysis, normalization, or
library manifest versions.

| Layer | Responsibility |
| --- | --- |
| **RunPlayCore** | `PersonalHeatmap*` models, Web Mercator metric grid, Amanatides–Woo-style line rasterization, `PersonalHeatmapBuilder` aggregation |
| **RunPlayPlatform** | `RouteMapArea` polygons and map-rect fitting for areas |
| **RunPlayStudio** | `PersonalHeatmapViewModel`, workspace mode, sidebar/menu entry, SwiftUI map fills |

### Intensity semantics

Primary heat is the number of **distinct included workouts** whose route
traverses a cell. Within one workout, loops and dense GPS samples contribute at
most once per cell. Intensity is log1p-normalized against the maximum aggregated
count so low-frequency cells remain visible.

### Gap safety

Rasterization only walks adjacent valid points in the same effective route
segment. Pause/resume, track boundaries, inferred gaps, and discarded invalid
coordinates never draw a corridor between segments.

### Adaptive performance

Default rendered-cell budget is **5,000** polygons. When the filtered cell count
exceeds the budget, the builder doubles cell size until the result fits. All
included workouts are preserved; cells are not randomly dropped. Effective cell
size is exposed in the snapshot and UI.

### Workspace navigation

`AppWorkspaceMode` is `.workout`, `.comparison`, or `.personalHeatmap` — mutually
exclusive. Selecting a workout leaves heatmap; entering comparison leaves
heatmap; heatmap calculation runs off the main actor and does not block normal
library interaction beyond heatmap-local loading indicators.

### Native route metric coloring

Single-workout Apple Maps routes can be colored by Solid, Pace, Heart Rate, or
Corrected Elevation. `RouteMetricProfileBuilder` (Core) is the only source of
interval metrics, distance-weighted relative scales, and palette-independent
buckets. `RouteMetricMapLineBuilder` (Platform) coalesces buckets into a bounded
set of `RouteMapLine`s. Studio’s `WorkoutRouteMapViewModel` caches results off
the main actor and does not rebuild on replay ticks.

Comparison maps keep primary blue / comparison orange identity. The personal
heatmap retains its own density palette. Missing HR is neutral no-data, not a
median fill. Elevation uses `WorkoutAnalysisContext.elevationProfile` only.
Preference storage is UI-only (`@AppStorage`); no workout migration.

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

### RouteQualityProcessor

`RouteQualityProcessor` is the platform-neutral, local-only normalization
boundary. Importers choose a distance policy and then hand raw points to the
same ordered stages:

1. validate coordinates and optional numeric fields, normalize point order and
   elapsed values, and discard invalid source speed/pace samples;
2. identify an isolated interior coordinate spike only when both adjacent legs
   imply excessive speed, the direct neighbour bridge is plausible, and the
   detour is both materially longer and sufficiently distorted;
3. introduce an implicit segment boundary only when a large relocation is
   supported by implausible speed or a long interval and the following points
   form a coherent cluster;
4. normalize cumulative distance without adding distance across explicit or
   inferred segment boundaries and record per-segment provenance;
5. sanitize altitude for analysis without replacing finite source altitude on
   `RoutePoint`;
6. smooth each continuous, non-missing altitude run in the distance domain;
7. calculate threshold-confirmed ascent and descent independently per run; and
8. return retained points, an aligned `ElevationProfile`, persisted diagnostics,
   distance provenance, and non-fatal warnings.

`RoutePointSanitizer` remains a compatibility entry point and delegates to this
processor. Existing explicit route segments are authoritative. First/last
points and adjacent spike candidates are retained because they lack the
neighbourhood evidence required for conservative removal. Invalid or ambiguous
signals fall back to valid-coordinate behavior rather than deleting a route.
No map matching, routing, network elevation, telemetry, or source-file rewrite
is involved.

### RouteQualityPolicy defaults

All tunable route and elevation thresholds live in `RouteQualityPolicy`. The
running defaults deliberately favour retention:

| Policy value | Default | Role |
| --- | ---: | --- |
| Maximum plausible running speed | 12 m/s (43.2 km/h) | Evidence for coordinate discontinuities, never a sole rejection rule |
| Maximum source speed | 15 m/s (54 km/h) | Rejects impossible device speed so normalized geometry can derive a replacement |
| Stale zero-speed movement threshold | 1 m/s | Treats a recorded zero as missing when normalized movement clearly continues |
| Maximum stationary source speed | 1 m/s | Treats a positive device speed as stale when normalized geometry is stationary |
| Maximum source-speed/geometry disagreement | 4× | Rejects a supplied speed that materially disagrees with its normalized step |
| Maximum useful horizontal accuracy | 100 m | Poor accuracy can support a spike decision only when neighbours are better |
| Coordinate-spike minimum excess / distortion | 200 m / 3× | Requires a substantial detour through an isolated candidate; good neighbour accuracy may halve only the excess requirement |
| Implicit-gap minimum jump / long interval | 200 m / 120 s | A long interval is supporting evidence only when the route also relocates |
| Long-gap cadence discontinuity | 3× | The suspected gap must be at least three times the resumed sampling cadence, avoiding false gaps in uniformly sparse tracks |
| Relocated-cluster confirmation | 3 points | Uses time-derived plausible speed when timestamps are valid; falls back to a 200 m maximum step only when timing is unavailable |
| Legacy distance inference tolerance | max(20 m, 5% of geometry) | Preserves a legacy non-GPX series as device-supplied only when it materially differs from raw geometry |
| Plausible altitude range | -500...9,000 m | Preserves below-sea-level routes while rejecting impossible values |
| Altitude-spike evidence | 35 m deviation, neighbours within 12 m, at most 150 m travelled span | Rejects only a locally unsupported interior or one-sided endpoint vertical spike |
| Short altitude-excursion evidence | At most 2 samples, each at least 100 m from the returned baseline, at most 150 m travelled span | Rejects only an extreme, tightly bounded receiver plateau while retaining sustained terrain changes |
| Elevation smoothing radius | 15 m (30 m full window) | Makes smoothing stable across sampling rates while preserving run endpoints |
| Minimum reliable altitude run | 2 samples | A lone sample may remain displayable but cannot produce meaningful gain/loss |
| Gain/loss deadband | 3 m | Confirms trend reversals before committing ascent or descent |
| Elevation-highlight window | 20% of total distance, clamped to 100...1,000 m | Defines one comparable continuous window for biggest climb/descent |
| Elevation-highlight evaluation step | max(25 m, window / 10) | Bounds window evaluations while retaining useful distance resolution |
| Cancellation stride | 2,048 points | Bounds cooperative cancellation latency in long processing loops |

### Distance-source precedence and provenance

A complete, finite, non-negative, monotonic device-distance series is preferred
when the importer can establish it. It is rebased at every compact segment
boundary and is never allowed to decrease. FIT evaluates supplied distance per
segment; TCX and JSON preserve it only when the complete supplied series is
valid. GPX derives distance from retained coordinates. Invalid or missing
series fall back to Haversine geometry after spike removal, and neither path
adds a jump across a gap.

`RouteDistanceSource` records the normalized workout as coordinate-derived,
device-supplied, mixed, or legacy-unknown. `RouteDistanceProvenance` records the
decision for each compact segment. Persisting both prevents a later migration
from guessing away a valid device series. Legacy snapshots without provenance
use a conservative source-aware inference: GPX remains coordinate-derived;
other complete monotonic series are retained only when they materially differ
from raw geometry.

### ElevationProfile and WorkoutAnalysisContext

`RoutePoint.altitudeMeters` is the finite altitude read from the source. The
processor does not overwrite it with corrected data. `ElevationProfile` is a
one-to-one derived view that exposes corrected altitude, source-rejection state,
cumulative ascent/descent, corrected altitude at cumulative distance, and
ascent, descent, or signed change over a distance range.

Each continuous non-missing altitude run is processed independently. Broad
range validation first rejects impossible values. Local checks can then reject
one unsupported interior or one-sided endpoint sample, or an extreme plateau of
at most two interior samples, only when the comparison baseline agrees and the
candidate occupies at most 150 m of travelled normalized distance. This
travelled span preserves legitimate switchbacks whose endpoint coordinates
happen to be close. A single rejected interior sample can be filled only from
its immediate reliable neighbours in the same segment; rejected endpoints and
adjacent rejected samples remain gaps. A centred rolling average then uses a
15 m distance radius and keeps reliable run endpoints. Missing spans and route
boundaries remain gaps. Runs shorter than two samples keep their sanitized
source values but return no meaningful gain/loss.

Gain and loss use a 3 m trend-reversal deadband. Minor oscillations do not
commit ascent or descent; a sustained trend is included, and a confirmed
reversal commits the prior trend exactly once. This is threshold-confirmed
cumulative ascent/descent, not a sum of every positive or negative adjacent
sample.

`WorkoutAnalyzer` creates one immutable `WorkoutAnalysisContext` containing the
profile and its `WorkoutTimeline`, then shares it with summary, split, and
notable-segment calculation. Biggest climb/descent evaluates a window equal to
20% of route distance clamped to 100...1,000 m, stepping by the larger of 25 m
or one tenth of the window. It selects the largest threshold-confirmed
ascent/descent only when the full window has continuous reliable elevation; it
never uses raw endpoints or bridges a gap. UI and platform code receive the
same immutable profile, with `AppState` retaining context values by workout
rather than using a global mutable cache. Charts, route colouring/projection,
comparison, replay metrics, and exports therefore use the same correction.

### MovementProfile

`MovementProfile` is another immutable analysis product created from normalized
route points and the authoritative `WorkoutTimeline`. It classifies same-segment
intervals as moving, stopped, paused, or uncertain using geometric speed,
displacement, cumulative distance, dwell time, and hysteresis. A resumed state
requires sustained evidence by duration or distance. Paused intervals remain
owned by `WorkoutTimeline` and never count as moving or stopped. Uncertain
active time counts as moving. Sparse or irregular timing uses the conservative
fallback `moving = active`, `stopped = 0`; compact `MovementDiagnostics` are
persisted while detailed interval state is derived at runtime.

JSON summary export carries normalization version, route-distance provenance,
quality diagnostics, warnings, and an `elevationAnalysis` description. Segment
JSON pairs `elevationMetric` with `correctedElevationValueMeters`; corrected
ascent/descent are positive magnitudes matching the UI subtitle, while the
legacy `elevationDeltaMeters` field remains a signed compatibility value. Split
CSV uses `Corrected_Elevation_Gain_m`; segment CSV pairs `Elevation_Metric` with
`Corrected_Elevation_Value_m`; and PNG summary labels use `Corrected Gain` and
`Corrected Loss`. Raw route-point altitude remains source data in snapshots.

### WorkoutTimeline

`WorkoutTimeline` is the platform-neutral clock and distance authority consumed by
`WorkoutAnalyzer`, `SplitCalculator`, `SegmentDetector`, `PlaybackEngine`,
`WorkoutComparisonService`, and export models. Its elevation APIs delegate to
the `ElevationProfile` supplied by the shared analysis context rather than
maintaining a raw-delta implementation.

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
sample is created. A split may aggregate corrected ascent from multiple
continuous runs while interpolation remains confined to each run.

### Workout library persistence

`WorkoutLibraryStoring`, `FileWorkoutLibraryStore`, and
`WorkoutLibraryManifest` live in `RunPlayCore`. The store writes complete
normalized workout snapshots beneath Application Support using atomic writes.
`RunPlayStudio` supplies the production root URL and applies background load
results to `AppState`; bundled demos remain SwiftPM resources rather than user
library entries.

`RunWorkout.normalizationVersion` versions route-point normalization separately
from `analysisVersion`. Missing fields decode as legacy version `0`. During
actor-isolated loading, migration first decodes the compatible source model,
then upgrades normalization when required, builds the shared context,
recomputes analysis, and atomically replaces the snapshot. An analysis-only
upgrade may preserve already-current normalized route points. Current snapshots
are not rewritten on every launch.

Normalization preserves workout identity, metadata, source, retained
route-point IDs, library order, and selection; deliberately rejected points are
removed and segment indexes are compacted. A failed upgrade write leaves the
original disk snapshot intact, keeps the upgraded or decoded workout visible in
memory, reports a library warning, and retries on the next launch. The manifest
schema does not change.

### Performance and cancellation

Quality processing uses compact segment ranges, rolling distance windows,
reserved arrays, binary-search distance sampling, and linear timestamp-run
resolution. Sorting within source segments bounds normalization at O(n log n).
With `runningDefault`, coordinate, distance, smoothing, and cumulative-profile
work is linear; neighbourhood confirmation remains O(n × k), where the policy
keeps `k` to at most three relocated-cluster points or two altitude-excursion
samples. No stage scans the full route once per point, and no unsafe global
cache is introduced.

Distance-stepped split, segment, comparison, and chart work uses a fixed
`RouteAnalysisBudget`: at most 100,000 evaluations, scaled to eight evaluations
per route point with a minimum budget of 1,000. Impossible split cardinality is
returned as unavailable instead of allocating an unbounded result.

Long processor, elevation, and derived-analysis loops check cancellation.
Interactive import propagates `CancellationError` instead of converting it to a
parse failure. Analyzer work is assembled in a local copy and assigned only
after quality, summary, splits, and highlights complete, while persistence
checks cancellation before beginning the transaction. A cancelled pass
therefore cannot expose a partially analyzed workout or leave a partial library
entry. Synchronous library migration uses the same deterministic processor
without task cancellation because its recovery path must return every decodable
workout.

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

The `elevationGain` compatibility entry point delegates to `ElevationProfile`;
it does not maintain an independent raw-altitude delta algorithm.

### WorkoutComparisonService

Route comparison is intentionally distance-based for the MVP. It does not do
dynamic time warping or complex route matching.

```swift
public struct WorkoutComparisonService {
    public func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary
    public func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison]
    public func compareRecordedLaps(primary: RunWorkout, comparison: RunWorkout) -> [RecordedLapComparison]
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
Recorded laps are paired by ordinal only, with unavailable results and caveats
for missing laps, legacy snapshots, count/trigger differences, or materially
different lap distances; they are never presented as route-aligned intervals.

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


## Strava bulk-export archive import

- **RunPlayCore** owns archive-independent candidate models, RFC 4180 CSV parsing,
  GZIP envelope decoding, path validation, sport policy, `WorkoutImportInput`
  data importers, `WorkoutImportProvenance`, and staged batch library APIs.
- **RunPlayPlatform** owns ZIP access via vendored ZIPFoundation 0.9.20,
  SHA-256 content hashing (CryptoKit), and `StravaArchiveService` (actor).
- **RunPlayStudio** owns the file picker, review/progress/report sheet, and
  AppState orchestration. Archive parsing never runs on `@MainActor`.
- Persistence uses a private `.staging/<batch-id>/` directory, then a single
  atomic manifest commit. The personal heatmap refreshes once after commit.
