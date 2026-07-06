# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → Normalized Model → Analyzer → Route Projection → Replay Controller → Views
                                                        ↘ Comparison Service → Compare View
                                                        ↘ Comparison Route Projection → 3D Comparison View
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: Convert to `RunWorkout` with `RoutePoint` array
4. **Analyze**: `WorkoutAnalyzer` calculates distance, pace, elevation, splits
5. **Project**: `RouteProjectionService` converts lat/lng to local 3D coordinates
6. **Control**: `ReplayController` manages playback state and timeline
7. **Render**: Views display 3D scene, map, charts, and summaries
8. **Compare**: `WorkoutComparisonService` compares two loaded workouts by summary metrics, split index, and distance-aligned metric series

## Module Structure

```
RunPlayStudio/
├── Sources/
│   ├── Models/          # Data structures
│   ├── Importers/       # File format parsers
│   ├── Services/        # Analysis and projection
│   ├── ViewModels/      # View state management
│   ├── Views/           # SwiftUI views
│   └── 3D/              # SceneKit 3D rendering
├── Resources/           # Sample data
└── Tests/               # Unit tests
```

## Key Abstractions

### WorkoutImporting Protocol

All importers conform to `WorkoutImporting`:

```swift
protocol WorkoutImporting {
    var supportedFormats: [UTType] { get }
    func importWorkout(from url: URL) throws -> RunWorkout
}
```

### Rendering Backend

3D rendering uses a `RouteSceneBuilding` protocol:

```swift
protocol RouteSceneBuilding {
    func buildScene(from points: [RouteScenePoint]) -> SCNScene
    func updateMarkerPosition(_ point: RouteScenePoint)
}
```

This allows swapping SceneKit for RealityKit later without changing analysis code.

### WorkoutComparisonService

Route comparison is intentionally distance-based for the MVP. It does not do
dynamic time warping or complex route matching.

```swift
struct WorkoutComparisonService {
    func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary
    func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison]
    func compareMetricsOverDistance(primary: RunWorkout, comparison: RunWorkout) -> [ComparisonMetricPoint]
    func commonDistance(primary: RunWorkout, comparison: RunWorkout) -> Double
    func metricsAtDistance(_ distance: Double, primary: RunWorkout, comparison: RunWorkout, primaryScenePoints: [RouteScenePoint], comparisonScenePoints: [RouteScenePoint]) -> ComparisonDistanceMetrics
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
struct ComparisonRouteProjectionService {
    var elevationExaggeration: Double = 2.0
    func project(primary: [RoutePoint], comparison: [RoutePoint], existingWarnings: [ComparisonWarning]) -> ComparisonRouteScene
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
}
```

Renders primary (blue) and comparison (orange) routes with distinct start/finish
markers, a shared ground grid, and a 3D legend.

## Dependencies

### Apple Frameworks Used

- **SwiftUI**: App UI and views
- **MapKit**: 2D map route display
- **Swift Charts**: Pace, elevation, heart rate charts
- **SceneKit**: 3D route visualization
- **CoreLocation**: Distance and coordinate calculations
- **UniformTypeIdentifiers**: File import
- **Foundation**: Parsing and models

### Third-Party Dependencies

**None** — MVP uses only Apple-native frameworks.

## Future Considerations

- RealityKit backend for 3D (if SceneKit limitations arise)
- AVFoundation for video export
- HealthKit for direct Apple Health import
