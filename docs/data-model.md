# RunPlay Studio — Data Model

## Time terminology

- **Elapsed time** is the final route timestamp minus the initial route
  timestamp. It includes pauses and recording gaps. When timestamps do not
  span but normalized route points carry a valid elapsed series, that series is
  used instead.
- **Active time** is the sum of positive timestamp deltas between adjacent
  points with the same `routeSegmentIndex`. The elapsed-series fallback treats
  all elapsed time as active because pause boundaries cannot be determined.
- **Paused time** is elapsed minus active, clamped to a finite non-negative
  value.
- **Moving time** is not estimated. Active time must not be presented as moving
  time.

`WorkoutTimeline` is the platform-neutral authority for these clocks. It also
derives active time at each point, clock values at cumulative distance, and the
route state at an elapsed replay time without mutating or persisting another
clock on every route point.

## Core Types

### RunWorkout

The top-level container for a running workout.

```swift
struct RunWorkout: Identifiable, Codable, Hashable {
    let id: UUID
    var metadata: WorkoutMetadata
    var source: WorkoutSource
    var routePoints: [RoutePoint]
    var splits: [RunSplit]
    var summary: RunSummary
    var segments: [SegmentHighlight]
    var analysisVersion: Int
    var analysisWarnings: [WorkoutAnalysisWarning]
}
```

Snapshots without `analysisVersion` decode as legacy version `0`. The current
version is reanalysed from stored route points during library load and then
atomically rewritten. Identity, metadata, source, route points, library order,
and selection are preserved.

### RoutePoint

A single GPS point along the route with optional biometric data.

```swift
struct RoutePoint: Identifiable, Codable {
    let id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var distanceFromStartMeters: Double
    var elapsedSeconds: Double
    var speedMetersPerSecond: Double?
    var paceSecondsPerKilometer: Double?
    var heartRateBPM: Double?
    var cadence: Double?
    var horizontalAccuracy: Double?
    var routeSegmentIndex: Int
}
```

`routeSegmentIndex` identifies the continuous source track containing the
point. It is zero-based after normalization. Rendering and analysis do not
connect points with different indexes. Older persisted snapshots omit this
field and decode with index `0` for backward compatibility.

`elapsedSeconds` always means elapsed time since the workout's first route
timestamp. It is never rewritten to remove pauses. Active time is derived by
`WorkoutTimeline`.

### RunSplit

A kilometer or mile split with summary metrics.

```swift
struct RunSplit: Identifiable, Codable {
    let id: UUID
    var splitIndex: Int          // 1-based
    var distanceMeters: Double   // 1000 for 1km splits
    var elapsedSeconds: Double
    var activeSeconds: Double
    var paceSecondsPerKilometer: Double        // active pace
    var elapsedPaceSecondsPerKilometer: Double
    var averageHeartRateBPM: Double?
    var elevationGainMeters: Double?
    var startDistanceMeters: Double
    var endDistanceMeters: Double
}
```

Splits follow global cumulative distance across route-segment boundaries. Only
the final workout remainder is partial. For an exact duplicate distance at a
stop/resume boundary, a range start uses the resumed segment's first point and
a range end uses the prior segment's final point. Time can aggregate across
segments, but coordinate/elevation interpolation never crosses a gap.

### RunSummary

Aggregated metrics for the entire run.

```swift
struct RunSummary: Codable {
    var totalDistanceMeters: Double
    var totalElapsedSeconds: Double
    var totalActiveSeconds: Double
    var totalPausedSeconds: Double
    var averagePaceSecondsPerKilometer: Double       // active pace
    var elapsedPaceSecondsPerKilometer: Double
    var averageSpeedMetersPerSecond: Double          // active speed
    var elapsedAverageSpeedMetersPerSecond: Double
    var elevationGainMeters: Double
    var elevationLossMeters: Double
    var averageHeartRateBPM: Double?
    var maxHeartRateBPM: Double?
    var caloriesEstimate: Double?
}
```

All clock, pace, and speed values are finite and non-negative. No-pause routes
have equal elapsed and active values. The compatibility names
`averagePaceSecondsPerKilometer` and `averageSpeedMetersPerSecond` retain active
semantics; explicit elapsed variants are additive.

### WorkoutSource

Where the workout data came from.

```swift
enum WorkoutSource: String, Codable {
    case json
    case gpx
    case tcx
    case fit
    case healthKit
    case strava
    case garmin
    case unknown
}
```

Pace-based fastest/slowest windows use active time and may span route-segment
boundaries in cumulative distance. Their `durationSeconds` is active duration;
elapsed endpoints remain available separately. Elevation deltas never bridge a
route gap.

### WorkoutMetadata

Optional metadata about the workout.

```swift
struct WorkoutMetadata: Codable {
    var name: String?
    var notes: String?
    var activityType: String      // "running", "trail_running", etc.
    var startDate: Date?
    var endDate: Date?
    var deviceName: String?
}
```

### SegmentHighlight

A notable segment of the route (fastest 400m, biggest climb, etc.)

```swift
struct SegmentHighlight: Identifiable, Codable, Hashable {
    let id: UUID
    var type: SegmentType
    var title: String
    var subtitle: String
    var startDistanceMeters: Double
    var endDistanceMeters: Double
    var startElapsedSeconds: Double
    var endElapsedSeconds: Double
    var durationSeconds: Double
    var distanceMeters: Double
    var paceSecondsPerKilometer: Double?
    var elevationDeltaMeters: Double?
    var averageHeartRate: Double?
    var sourcePointRange: Range<Int>
    var displayPriority: Int
}

enum SegmentType: String, Codable, Hashable, CaseIterable {
    case fastest400m
    case fastest1km
    case slowest1km
    case biggestClimb
    case biggestDescent
    case slowdown
    case custom
}
```

## Comparison Types

### ComparisonPair

The selected primary and comparison workouts.

```swift
struct ComparisonPair {
    let primary: RunWorkout
    let comparison: RunWorkout
}
```

### WorkoutComparisonSummary

Summary deltas and individual values between two completed runs.

```swift
struct WorkoutComparisonSummary {
    let primaryTitle: String
    let comparisonTitle: String

    // Distance (primary, comparison, delta)
    let primaryDistanceMeters: Double
    let comparisonDistanceMeters: Double
    let distanceDeltaMeters: Double

    // Explicit clocks
    let primaryElapsedSeconds: Double
    let comparisonElapsedSeconds: Double
    let elapsedTimeDeltaSeconds: Double
    let primaryActiveSeconds: Double
    let comparisonActiveSeconds: Double
    let activeTimeDeltaSeconds: Double
    let primaryPausedSeconds: Double
    let comparisonPausedSeconds: Double
    let pausedTimeDeltaSeconds: Double

    // Active and elapsed pace
    let primaryPaceSecondsPerKm: Double
    let comparisonPaceSecondsPerKm: Double
    let paceDeltaSecondsPerKm: Double
    let primaryElapsedPaceSecondsPerKm: Double
    let comparisonElapsedPaceSecondsPerKm: Double
    let elapsedPaceDeltaSecondsPerKm: Double

    // Elevation
    let primaryElevationGainMeters: Double
    let comparisonElevationGainMeters: Double
    let elevationGainDeltaMeters: Double

    // Heart rate (optional)
    let primaryAvgHR: Double?
    let comparisonAvgHR: Double?
    let avgHRDelta: Double?
    let primaryMaxHR: Double?
    let comparisonMaxHR: Double?
    let maxHRDelta: Double?

    let primaryPointCount: Int
    let comparisonPointCount: Int
    let warnings: [ComparisonWarning]
}
```

### SplitComparison

Split-by-split comparison aligned by split index.

```swift
struct SplitComparison: Identifiable {
    let splitIndex: Int
    let primarySplit: RunSplit?
    let comparisonSplit: RunSplit?
    let elapsedDurationDeltaSeconds: Double?
    let activeDurationDeltaSeconds: Double?
    let paceDeltaSecondsPerKm: Double?
    let winner: ComparisonResult
}
```

### ComparisonMetricPoint

Distance-aligned sample used by the comparison chart.

```swift
struct ComparisonMetricPoint: Identifiable {
    let distanceMeters: Double
    let primaryPace: Double?
    let comparisonPace: Double?
    let paceDelta: Double?
    let primaryElevation: Double?
    let comparisonElevation: Double?
    let primaryHR: Double?
    let comparisonHR: Double?
}
```

### ComparisonWarning

Warnings returned for comparisons that are still possible but weak.

```swift
enum ComparisonWarning {
    case differentDistances
    case insufficientOverlap
    case differentRouteShape
    case missingHeartRate
    case missingElevation
    case tooFewPoints
    case differentPauseDurations
}
```

### ComparisonDistanceMetrics

Metrics at a user-selected distance along both comparison routes.

```swift
struct ComparisonDistanceMetrics {
    let selectedDistanceMeters: Double
    let primaryElapsedSeconds: Double?
    let comparisonElapsedSeconds: Double?
    let timeDeltaSeconds: Double?              // elapsed compatibility alias
    let primaryActiveSeconds: Double?
    let comparisonActiveSeconds: Double?
    let activeTimeDeltaSeconds: Double?
    let primaryPaceSecondsPerKm: Double?
    let comparisonPaceSecondsPerKm: Double?
    let paceDeltaSecondsPerKm: Double?
    let primaryScenePoint: RouteScenePoint?
    let comparisonScenePoint: RouteScenePoint?
}
```

Selected-distance clocks use `WorkoutTimeline` and the same explicit duplicate
boundary rule as splits. Active pace is cumulative active time divided by the
covered distance.

## 3D Types

### ComparisonRouteScene

Result of projecting two routes into a shared 3D coordinate space.

```swift
struct ComparisonRouteScene {
    let primaryRoute: [RouteScenePoint]
    let comparisonRoute: [RouteScenePoint]
    let combinedBounds: (min: SIMD3<Double>, max: SIMD3<Double>)
    let warnings: [ComparisonWarning]
    var hasValidRoutes: Bool
    var maxExtent: Double
    var center: SIMD3<Double>
}
```

### RouteScenePoint

A route point projected into 3D local coordinates.

```swift
struct RouteScenePoint: Identifiable {
    let id: UUID
    var xMeters: Double
    var yMeters: Double         // elevation
    var zMeters: Double
    var sourceIndex: Int        // index into RoutePoint array
    var distanceFromStartMeters: Double
    var elapsedSeconds: Double
    var paceSecondsPerKilometer: Double?
    var heartRateBPM: Double?
}
```

## State Types

### ReplayState

Controls for the route replay.

```swift
enum PlaybackState {
    case stopped
    case playing
    case paused
}

struct ReplayState {
    var playbackState: PlaybackState
    var currentTime: Double          // elapsed seconds from start
    var currentDistance: Double       // meters from start
    var currentPointIndex: Int
    var playbackSpeed: Double        // 1.0, 2.0, 0.5, etc.
    var totalDuration: Double        // total elapsed seconds
    var totalDistance: Double

    // Computed properties
    var progress: Double             // 0...1 fraction of duration
    var distanceProgress: Double     // 0...1 fraction of distance
    var formattedCurrentTime: String
    var formattedTotalDuration: String
    var formattedCurrentDistance: String
    var formattedSpeed: String
}
```

Replay uses the elapsed clock. During a recording gap the latest route point at
or before `currentTime` remains selected until the exact resume timestamp.
`SelectedMetrics` exposes elapsed time, active time, distance, point metrics,
and `isInRecordingGap`; active time and distance hold while elapsed advances.

## Migration limitation

Legacy snapshots that already contain `routeSegmentIndex` can recover correct
pause semantics through reanalysis. Older snapshots that predate that field
decode every point into segment `0`; a pause boundary absent from the stored
route cannot be reconstructed and the original activity must be reimported.
