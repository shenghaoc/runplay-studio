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
    Services/         # Analysis, splits, segments, comparison, export
  Tests/
    RunPlayCoreTests/ # Platform-neutral tests

RunPlayStudio/        # macOS executable (SwiftUI, MapKit)
  Sources/
    Views/            # SwiftUI views
    ViewModels/       # AppState, ReplayController
    3D/               # Legacy SceneKit prototype utilities (not the shipped map UI)
    Services/         # macOS-only services (PNG export, route coloring)
  Tests/
    RunPlayStudioTests/ # macOS-specific tests
  Resources/          # Sample data and fixtures
```

## Build & Test Commands

### Core-only (platform-neutral, Codex Cloud compatible)

```bash
# Build core library
swift build --target RunPlayCore

# Run core tests only
swift test --filter RunPlayCoreTests
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

### RunPlayCore — Platform-Neutral Target

- **No** SwiftUI, AppKit, MapKit, Charts, CoreLocation
- Uses `GeoDistance` (haversine) instead of `CLLocation.distance(from:)`
- Uses `#if canImport(FoundationXML)` for Linux XML parsing
- All types are `public` for cross-module access
- `PNGExportRenderer` stays in RunPlayStudio (requires AppKit)

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

- macOS build/test: `swift test`
- Core-only test: `swift test --filter RunPlayCoreTests`
- Linux CI: `swift build --target RunPlayCore && swift test --filter RunPlayCoreTests` (Ubuntu, Swift 5.9+)
