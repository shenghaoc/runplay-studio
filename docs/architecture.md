# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → RoutePointSanitizer → Normalized Model → Analyzer → Route Projection → Replay Controller → Views
                                                     ↘ Comparison Service → Compare View
                                                     ↘ Comparison Route Projection → 3D Comparison View
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: `RoutePointSanitizer` validates coordinates, ensures monotonic elapsed time and distance
4. **Analyze**: `WorkoutAnalyzer` calculates distance, pace, elevation, splits, segments
5. **Project**: `RouteProjectionService` converts lat/lng to local 3D coordinates
6. **Control**: `ReplayController` manages playback state and timeline
7. **Render**: Views display 3D scene, map, charts, and summaries
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

RunPlayStudio/                 # macOS executable (SwiftUI, SceneKit, MapKit)
├── Sources/
│   ├── Services/              # macOS-only services (PNG export, route coloring)
│   ├── ViewModels/            # View state management (AppState, ReplayController)
│   ├── Views/                 # SwiftUI views
│   └── 3D/                    # SceneKit 3D rendering
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

The `WorkoutImporterFactory` dispatches by file extension. The SwiftUI file picker uses `UTType(filenameExtension:)` so `.tcx` and `.fit` files are selectable even without system UTI declarations.

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
elapsed time, pace, and 3D scene position at any selected distance.

### ComparisonRouteProjectionService

Projects two routes into a shared local coordinate system for 3D comparison:

```swift
public struct ComparisonRouteProjectionService {
    public var elevationExaggeration: Double = 2.0
    public func project(primary: [RoutePoint], comparison: [RoutePoint], existingWarnings: [ComparisonWarning]) -> ComparisonRouteScene
}
```

Uses the primary route's bounding-box center as the shared origin so both routes
maintain correct relative geographic positions. Filters invalid/NaN coordinates,
applies elevation exaggeration consistently, and returns a `ComparisonRouteScene`
with combined bounds and warnings.

### ComparisonSceneBuilder

Builds a SceneKit scene for 3D comparison:

```swift
class ComparisonSceneBuilder {
    func buildScene(from comparisonScene: ComparisonRouteScene) -> SCNScene
    func routeBoundingBox(for comparisonScene: ComparisonRouteScene) -> (center: SCNVector3, extent: CGFloat)
    func updateDistanceMarkers(in scene: SCNScene, primaryPoint: RouteScenePoint?, comparisonPoint: RouteScenePoint?)
}
```

Renders primary (blue) and comparison (orange) routes with distinct start/finish
markers, a shared ground grid, and a 3D legend.

### Camera Convention

The camera uses a spherical coordinate system with:
- `cameraAngleX`: elevation angle in degrees. Positive = camera above target (looking down). Range: 1° to 89°.
- `cameraAngleY`: azimuth angle in degrees. 0° = front, 90° = right side.
- Presets: default (30°, 45°), top-down (85°, 0°), side (5°, 0°), front (10°, 90°).

## Dependencies

### Apple Frameworks Used (RunPlayStudio only)

- **SwiftUI**: App UI and views
- **MapKit**: 2D map route display
- **Swift Charts**: Pace, elevation, heart rate charts
- **SceneKit**: 3D route visualization
- **UniformTypeIdentifiers**: File import
- **Foundation**: Parsing and models

### Platform-Neutral (RunPlayCore)

- **Foundation**: Parsing and models
- **FoundationXML**: XML parsing on Linux (conditional import)

### Third-Party Dependencies

**None** — MVP uses only Apple-native frameworks.

## Future Considerations

- RealityKit backend for 3D (if SceneKit limitations arise)
- AVFoundation for video export
- HealthKit for direct Apple Health import
