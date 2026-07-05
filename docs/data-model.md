# RunPlay Studio — Data Model

## Core Types

### RunWorkout

The top-level container for a running workout.

```swift
struct RunWorkout: Identifiable, Codable {
    let id: UUID
    var metadata: WorkoutMetadata
    var source: WorkoutSource
    var routePoints: [RoutePoint]
    var splits: [RunSplit]
    var summary: RunSummary
}
```

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
}
```

### RunSplit

A kilometer or mile split with summary metrics.

```swift
struct RunSplit: Identifiable, Codable {
    let id: UUID
    var splitIndex: Int          // 1-based
    var distanceMeters: Double   // 1000 for 1km splits
    var elapsedSeconds: Double
    var paceSecondsPerKilometer: Double
    var averageHeartRateBPM: Double?
    var elevationGainMeters: Double?
    var startDistanceMeters: Double
    var endDistanceMeters: Double
}
```

### RunSummary

Aggregated metrics for the entire run.

```swift
struct RunSummary: Codable {
    var totalDistanceMeters: Double
    var totalElapsedSeconds: Double
    var averagePaceSecondsPerKilometer: Double
    var averageSpeedMetersPerSecond: Double
    var elevationGainMeters: Double
    var elevationLossMeters: Double
    var averageHeartRateBPM: Double?
    var maxHeartRateBPM: Double?
    var caloriesEstimate: Double?
}
```

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

A notable segment of the route (fastest mile, steepest climb, etc.)

```swift
struct SegmentHighlight: Identifiable, Codable {
    let id: UUID
    var type: SegmentType
    var startIndex: Int          // RoutePoint index
    var endIndex: Int
    var startDistanceMeters: Double
    var endDistanceMeters: Double
    var value: Double            // pace, gradient, etc.
    var label: String
}

enum SegmentType: String, Codable {
    case fastestKilometer
    case fastestMile
    case steepestClimb
    case steepestDescent
    case slowestKilometer
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

Summary deltas between two completed runs.

```swift
struct WorkoutComparisonSummary {
    let primaryTitle: String
    let comparisonTitle: String
    let distanceDeltaMeters: Double
    let durationDeltaSeconds: Double
    let paceDeltaSecondsPerKm: Double
    let elevationGainDeltaMeters: Double
    let avgHRDelta: Double?
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
    let durationDeltaSeconds: Double?
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
}
```

## 3D Types

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
    var currentTime: Double          // seconds from start
    var currentDistance: Double       // meters from start
    var currentPointIndex: Int
    var playbackSpeed: Double        // 1.0, 2.0, 0.5, etc.
    var totalDuration: Double
    var totalDistance: Double
}
```
