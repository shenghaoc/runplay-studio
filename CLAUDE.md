# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
# Full build and test (macOS)
swift build
swift test

# Core only (cross-platform, Linux-compatible)
swift build --target RunPlayCore
swift test --filter RunPlayCoreTests

# Platform layer only (macOS, no SwiftUI)
swift build --target RunPlayPlatform
swift test --filter RunPlayPlatformTests

# Single test class or method
swift test --filter RunPlayCoreTests/GeoDistanceTests
swift test --filter RunPlayStudioTests/WorkoutComparisonTests/testComparisonBasic

# Open in Xcode
open Package.swift
```

CI uses `-Xswiftc -warnings-as-errors` — compiler warnings fail the build.

## Architecture

Three-layer Swift Package: `RunPlayStudio → RunPlayPlatform → RunPlayCore`. Reverse dependencies are forbidden.

**RunPlayCore** — Cross-platform logic (Foundation only). Builds on macOS and Linux. Contains models (`RunWorkout`, `RoutePoint`), importers (`WorkoutImporting` protocol + `WorkoutImporterFactory`), and services (analysis, splits, segments, comparison, export, `PlaybackEngine`). All types are `public` and `Sendable`.

**RunPlayPlatform** — macOS non-UI adapters. SceneKit 3D builders, AppKit color mapping (`RouteColoringService`), MapKit data types. No SwiftUI or Charts. Declared inside `#if os(macOS)` in Package.swift.

**RunPlayStudio** — macOS GUI. SwiftUI views, Charts, app lifecycle. `AppState` is the central `@MainActor ObservableObject`. `ReplayController` wraps `PlaybackEngine` with Combine/Timer at 30fps.

## Key Constraints

- **Swift 6.3**, Swift 6 language mode (strict concurrency), deployment target macOS 26
- **Zero external dependencies** — pure Apple frameworks only
- **RunPlayCore imports**: only Foundation + `FoundationXML` (via `#if canImport`). Never import SwiftUI, AppKit, SceneKit, MapKit, Charts, CoreLocation, or Combine in Core.
- Use `GeoDistance` (haversine) for coordinate math in Core — not `CLLocation.distance(from:)`
- Use `#if canImport(FoundationXML)` for XML parsing to support Linux
- **Never commit directly to `main`** — always use feature branches and PRs
- **Privacy**: local-only processing, no cloud/telemetry/AI APIs. Private workout files go in `local-workouts/` or `private-workouts/` (gitignored). Committed fixtures must be synthetic.

## Import Pattern

All importers conform to `WorkoutImporting` (with `supportedExtensions` and `importWorkout(from:)`). `WorkoutImporterFactory` dispatches by file extension. File picker allows generic file data so `.tcx`/`.fit` remain selectable; extension validation happens in the factory.

## CI

Two parallel jobs (no dependency between them):
- **core-linux**: Ubuntu 24.04 + Swift 6.3.3 — builds and tests RunPlayCore
- **macos**: macOS 26 + Xcode 26.4 — builds and tests all three layers
