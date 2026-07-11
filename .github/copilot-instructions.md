# Copilot Instructions — RunPlay Studio

## Build & Test Commands

```bash
# Full build and test (macOS)
swift build
swift test

# Core only (cross-platform, works on Linux)
swift build --target RunPlayCore
swift test --filter RunPlayCoreTests

# Platform layer only (macOS, no SwiftUI)
swift build --target RunPlayPlatform
swift test --filter RunPlayPlatformTests

# Run a single test class
swift test --filter RunPlayCoreTests/GeoDistanceTests
swift test --filter RunPlayStudioTests/WorkoutComparisonTests

# Open in Xcode
open Package.swift
```

CI uses `-Xswiftc -warnings-as-errors` — compiler warnings are treated as errors.

## Architecture

Three-layer Swift Package with strict dependency flow: `RunPlayStudio → RunPlayPlatform → RunPlayCore`. Reverse dependencies are forbidden.

### RunPlayCore (cross-platform)
- Pure Foundation logic — builds and tests on macOS and Linux
- Allowed imports: Foundation, `FoundationXML` (conditional via `#if canImport(FoundationXML)`)
- Forbidden: SwiftUI, AppKit, SceneKit, MapKit, Charts, CoreLocation, Combine
- Uses `GeoDistance` (haversine formula) instead of `CLLocation.distance(from:)`
- Contains: models (`RunWorkout`, `RoutePoint`), importers (`WorkoutImporting` protocol), services (analysis, splits, segments, comparison, export, playback)
- All types are `public` for cross-module access

### RunPlayPlatform (macOS non-UI)
- SceneKit 3D builders, AppKit color mapping, MapKit data types
- No SwiftUI, Charts, or presentation code
- Declared only inside `#if os(macOS)` in Package.swift

### RunPlayStudio (macOS GUI)
- SwiftUI views, Charts, app lifecycle, `@MainActor` UI state
- `ReplayController` wraps `PlaybackEngine` with Combine/Timer
- PNG export via `NSHostingView` (requires GUI context)

## Key Conventions

### Swift Version
- `swift-tools-version:6.3` with Swift 6 language mode (`swiftLanguageModes: [.v6]`)
- Deployment target: macOS 26

### Import Pattern
All importers conform to `WorkoutImporting` protocol. `WorkoutImporterFactory` dispatches by file extension. The file picker allows generic file data so `.tcx` and `.fit` remain selectable.

### Platform-Neutral Code
When adding logic to RunPlayCore:
- Use `GeoDistance` for coordinate math, not CoreLocation
- Use `#if canImport(FoundationXML)` for XML parsing on Linux
- Avoid Apple UI framework types

### Testing
- Core tests: `RunPlayCoreTests/` — platform-neutral, run on Linux CI
- Studio tests: `RunPlayStudioTests/` — macOS only, require UI frameworks
- Tests use `@testable import` for their module
- Test fixtures in `RunPlayStudio/Resources/` (synthetic data only)

### Privacy
- Local-only processing — no cloud backend, telemetry, or AI APIs
- Committed fixtures must be synthetic or anonymized
- Private workout files go in `local-workouts/` or `private-workouts/` (gitignored)
