# AGENTS.md — RunPlay Studio

## Branch & PR Workflow

- **Never commit directly to `main`.**
- Create a feature/fix branch from `main`.
- Make small, reviewable commits.
- Open PR(s) for review.
- Bug fixes must land via PRs, not direct mainline commits.
- No handoff-only commits. Never update a handoff file solely because the latest commit hash changed.
- `git log` is the source of truth for the latest commit.

## Repository Structure

```
RunPlayCore/          # Platform-neutral library (no UI frameworks)
  Sources/
    Models/           # Data types (RunWorkout, RoutePoint, etc.)
    Importers/        # JSON, GPX, TCX, FIT importers
    Services/         # Analysis, splits, segments, comparison, export, playback
    3D/               # Platform-neutral lookup helpers
  Tests/
    RunPlayCoreTests/ # Platform-neutral tests (builds on Linux)

RunPlayPlatform/      # macOS platform layer (no SwiftUI)
  Sources/
    Services/         # Route coloring (NSColor), map data types
    3D/               # SceneKit builders and camera controller
  Tests/
    RunPlayPlatformTests/ # macOS platform tests

RunPlayStudio/        # macOS GUI layer (SwiftUI, Charts)
  Sources/
    Views/            # SwiftUI views
    ViewModels/       # AppState, ReplayController (Combine/Timer wrapper)
    Services/         # GUI-specific services (SwiftUI PNG rendering/export)
  Tests/
    RunPlayStudioTests/ # macOS GUI tests
  Resources/          # Sample data and fixtures
```

## Build & Test Commands

### Core-only (platform-neutral, Linux compatible)

```bash
# Build core library
swift build --target RunPlayCore

# Run core tests only
swift test --filter RunPlayCoreTests
```

### Platform layer (macOS, no SwiftUI)

```bash
# Build platform library
swift build --target RunPlayPlatform

# Run platform tests
swift test --filter RunPlayPlatformTests
```

### Full macOS build and test

```bash
# Build everything
swift build

# Run all tests
swift test
```

### Xcode

```bash
open Package.swift
```

## Key Architecture Decisions

### Three-Layer Architecture

- **RunPlayCore** — Cross-platform Swift logic using Foundation and conditional FoundationXML only. It builds and tests on macOS and Linux.
- **RunPlayPlatform** — macOS non-UI adapters using SceneKit, AppKit value types, MapKit, and Combine. It contains no SwiftUI, Charts, views, or presentation code.
- **RunPlayStudio** — macOS UI and application layer. It owns SwiftUI, Charts, app lifecycle, views, view models, and UI rendering/export.

Dependency flow: `RunPlayStudio → RunPlayPlatform → RunPlayCore`

The reverse dependencies are forbidden: Core must not import Platform or Studio, and Platform must not import Studio. `Package.swift` keeps Core unconditional while declaring Platform and Studio only inside `#if os(macOS)`, so Linux never evaluates or builds the macOS layers.

### Swift Version Baseline

- `swift-tools-version:6.0` with Swift 6 language mode.
- Linux CI: Ubuntu 24.04 Arm64 with Swift 6.3.3 (pre-installed).
- macOS CI: macOS 26 + Xcode 26.6.

### RunPlayCore — Platform-Neutral Target

- Allowed imports: Foundation and `FoundationXML` behind `#if canImport(FoundationXML)`
- Forbidden imports: SwiftUI, AppKit, SceneKit, MapKit, Charts, CoreLocation, Combine
- Uses `GeoDistance` (haversine) instead of `CLLocation.distance(from:)`
- Uses `#if canImport(FoundationXML)` for Linux XML parsing
- All types are `public` for cross-module access
- Contains pure computation: `RouteColorMetrics`, `PlaybackEngine`

### RunPlayPlatform — macOS Platform Layer

- SceneKit 3D builders (`RouteSceneBuilder`, `ComparisonSceneBuilder`, `SceneCameraController`)
- AppKit color mapping (`RouteColoringService`)
- MapKit data types (`RouteMapData`)
- May use Combine for observable non-UI controllers
- **No** SwiftUI, Charts, `View` conformances, app lifecycle, or presentation code

### RunPlayStudio — macOS GUI Layer

- Owns SwiftUI/Charts views, app lifecycle, and `@MainActor` UI state
- `ReplayController` wraps `PlaybackEngine` with Combine/Timer
- PNG export with `ImageRenderer` and concrete SwiftUI views (`PNGExportRenderer`, `ExportServicePNGExtension`)

### File Import

- File picker allows generic file data so `.tcx` and `.fit` remain selectable in the Swift Package app path
- Extension validation happens in `WorkoutImporterFactory`

## Manual Smoke Checklist

### File Import
- [ ] Select `.tcx` file through import button
- [ ] Select `.fit` file through import button
- [ ] Select `.gpx` file through import button
- [ ] Select `.json` file through import button
- [ ] Reject unsupported file extension with clear error

### Map View
- [ ] 2D/3D toggle switches map pitch correctly
- [ ] Route displays with correct colors (blue primary, orange comparison)
- [ ] Start/finish annotations appear on route

### Replay
- [ ] Playback reaches end with correct final position
- [ ] Step forward/backward works with one-point workout
- [ ] Empty workout doesn't crash

### Charts
- [ ] Chart drag/seek works correctly
- [ ] HR chart shows "no data" when no HR exists

### Comparison
- [ ] Two routes overlay correctly on shared map
- [ ] Distance slider shows interpolated markers
- [ ] Blue = primary, orange = comparison

### Export
- [ ] JSON export produces valid JSON
- [ ] CSV export produces valid CSV
- [ ] PNG export works (requires GUI context)

## FIT Limitations

- Header and file CRCs are validated; a `0x0000` header CRC is treated as absent
- Compressed timestamp headers fail with a controlled unsupported-data error
- Only record messages (global message 20) are parsed
- Signed Int32 coordinate decoding uses bit-pattern semantics

## CI

- `core-linux` and `macos` are independent jobs with no `needs:` dependency, so GitHub Actions can run them in parallel.
- Linux Core gate: Ubuntu 24.04 Arm64 + Swift 6.3.3, then `swift build --target RunPlayCore` and `swift test --filter RunPlayCoreTests`.
- macOS full-stack gate: build and test Core, Platform, and Studio with `swift build` and `swift test`.
- Platform-only local gate: `swift build --target RunPlayPlatform` and `swift test --filter RunPlayPlatformTests`.
