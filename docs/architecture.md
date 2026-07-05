# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → Normalized Model → Analyzer → Route Projection → Replay Controller → Views
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: Convert to `RunWorkout` with `RoutePoint` array
4. **Analyze**: `WorkoutAnalyzer` calculates distance, pace, elevation, splits
5. **Project**: `RouteProjectionService` converts lat/lng to local 3D coordinates
6. **Control**: `ReplayController` manages playback state and timeline
7. **Render**: Views display 3D scene, map, charts, and summaries

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
- CloudKit sync (optional, privacy-preserving)
