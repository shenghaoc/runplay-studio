# RunPlay Studio — Project Structure

## Dependency Flow

```
RunPlayStudio → RunPlayPlatform → RunPlayCore
```

Reverse dependencies are forbidden. `RunPlayCore` must never import UI, map, graphics, CoreLocation, or Combine. Use `GeoDistance` (Haversine) instead of `CLLocation` for all core distance math.

## Module Breakdown

```
RunPlayCore/                   # Cross-platform library — builds on Linux
├── Sources/
│   ├── Models/                # Value types: RunWorkout, RoutePoint, RunSplit, RunSummary,
│   │                          #   SegmentHighlight, WorkoutMetadata, WorkoutSource, etc.
│   ├── Importers/             # Format parsers: GPX, TCX, FIT, JSON, HealthKit (stub)
│   │                          #   WorkoutImporting protocol + WorkoutImporterFactory
│   ├── Services/              # Analysis: WorkoutAnalyzer, SplitCalculator, SegmentDetector,
│   │                          #   GeoDistance, RoutePointSanitizer, PlaybackEngine,
│   │                          #   WorkoutComparisonService, ExportService,
│   │                          #   FileWorkoutLibraryStore, WorkoutLibraryStoreActor
│   └── 3D/                    # RouteScenePointLookup (platform-neutral 3D helpers)
└── Tests/RunPlayCoreTests/    # Platform-neutral tests (~174 tests)

RunPlayPlatform/               # macOS non-UI layer (SceneKit, MapKit, AppKit values, Combine)
├── Sources/
│   ├── Services/              # Route projection, map data services
│   └── 3D/                    # SceneKit scene building utilities
└── Tests/RunPlayPlatformTests/

RunPlayStudio/                 # macOS executable — SwiftUI app
├── Sources/
│   ├── Services/              # UI-adjacent: library loading, PNG export (NSHostingView)
│   ├── ViewModels/            # AppState, ReplayController (@MainActor observable state)
│   └── Views/                 # SwiftUI views (map, charts, splits, comparison, export)
├── Resources/                 # Bundled sample runs and fixtures (synthetic data only)
└── Tests/RunPlayStudioTests/
```

## Key Conventions

- **Models** are value types (`struct`/`enum`), `Codable`, `Sendable`-safe
- **Services** in `RunPlayCore` are `enum` namespaces or `struct`s with static/instance methods; no UI dependencies
- **ViewModels** are `@Observable` classes annotated `@MainActor`; they own replay and library state
- **Importers** all conform to `WorkoutImporting`; `WorkoutImporterFactory` dispatches by file extension
- **`routeSegmentIndex`** on `RoutePoint` marks GPS track boundaries (pause/resume gaps); renderers and analyzers must not connect points across segment boundaries

## Important Files

| File | Purpose |
|------|---------|
| `Package.swift` | Authoritative target/product definitions; macOS targets gated with `#if os(macOS)` |
| `RunPlayCore/Sources/Services/GeoDistance.swift` | Platform-neutral Haversine distance — use instead of CLLocation |
| `RunPlayCore/Sources/Services/RoutePointSanitizer.swift` | Normalizes raw route points; entry point after parsing |
| `RunPlayCore/Sources/Services/WorkoutLibraryStoreActor.swift` | Actor wrapping the library store for concurrent access |
| `RunPlayStudio/Sources/RunPlayStudioApp.swift` | App entry point, lifecycle, and production library root URL |
| `AGENTS.md` | Canonical agent rules — branch workflow, guardrails, validation commands |
| `docs/architecture.md` | Detailed data-flow and abstraction reference |
| `docs/data-model.md` | Full type definitions for all core models |

## Other Directories

| Directory | Purpose |
|-----------|---------|
| `docs/` | Architecture, data model, import formats, manual testing, privacy, phase plan |
| `.Jules/` | Durable agent learnings: `bolt.md` (perf), `palette.md` (a11y), `sentinel.md` (security) |
| `prompts/` | Historical feature-build prompts (reference only) |
| `scripts/` | `package-demo.sh` — builds unsigned `.app` artifact |
| `local-workouts/`, `private-workouts/` | Gitignored; safe location for real workout files |
| `.kiro/specs/` | Spec-driven feature work (requirements → design → tasks) |
