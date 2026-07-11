# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → RoutePointSanitizer → Normalized Model → Analyzer → Workout Library
                                                     ↘ Replay Controller → Views
                                                     ↘ Comparison Service → Compare View
                                                     ↘ Route Coordinates → MapKit 2D/3D View
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: `RoutePointSanitizer` validates coordinates, preserves route-segment boundaries, and ensures cumulative distance does not include a recording gap
4. **Analyze**: `WorkoutAnalyzer` calculates gap-safe distance, pace, elevation, splits, and segments
5. **Persist**: `FileWorkoutLibraryStore` atomically stores the normalized workout and versioned manifest
6. **Control**: `ReplayController` manages playback state and timeline
7. **Render**: Views display a MapKit 2D/3D route map, charts, and summaries
8. **Compare**: `WorkoutComparisonService` compares two loaded workouts by summary metrics, split index, and distance-aligned metric series

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

### Workout library persistence

`WorkoutLibraryStoring`, `FileWorkoutLibraryStore`, and
`WorkoutLibraryManifest` live in `RunPlayCore`. The store writes complete
normalized workout snapshots beneath Application Support using atomic writes.
`RunPlayStudio` supplies the production root URL and applies background load
results to `AppState`; bundled demos remain SwiftPM resources rather than user
library entries.

### GeoDistance

Platform-neutral distance calculation using the Haversine formula, replacing CoreLocation:

```swift
public enum GeoDistance {
    static func distanceMeters(fromLat: Double, lon: Double, toLat: Double, lon: Double) -> Double
    static func isValidCoordinate(lat: Double, lon: Double) -> Bool
}
```

### RoutePointInterpolator

Distance-based interpolation helpers used by SplitCalculator, SegmentDetector, and WorkoutComparisonService:

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
instead of crashing on weak comparisons. The `metricsAtDistance` method uses
linear interpolation between the two nearest points on each route to compute
elapsed time, pace, and selected route coordinates at any distance.

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
