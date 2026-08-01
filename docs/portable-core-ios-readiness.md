# Portable Core iOS Readiness

The engine, Core, and their validators are platform-neutral. This document
records what is portable today, where the Apple-only boundaries sit, and what a
future iOS product must validate. It is a durable reference; the package graph
(`Package.swift`) and the source conditions are executable truth.

## What is already platform-neutral

- **`RunPlayEngineCpp`** is portable C++23 using only the C++ standard library.
  No Apple framework, Foundation, Objective-C, or third-party dependency appears
  in the engine or its native tests. The boundary validator
  (`scripts/validate-cpp-boundaries.sh`) fails any engine source that imports an
  Apple framework.
- **`RunPlayCore`** is cross-platform Swift: Foundation plus a conditional
  `FoundationXML` import (GPX/TCX importers) and a `canImport(Darwin)` guard for
  localization. It imports no UI, map, graphics, Core Location, or Combine.
  `RunPlayCore` and its tests are the complete Swift-facing package graph on
  Linux.
- **Validators** (`validate-cpp-boundaries.sh`, `validate-cpp-public-ast.py`,
  `run-cpp-engine-tests.sh`) use `clang++` and `find` and are not macOS-specific.

## Apple-only paths

The following live outside the portable layers and are macOS-only by design:

- **`RunPlayPlatform`** — macOS non-UI adapters for SceneKit, AppKit, MapKit,
  and non-UI Combine, plus the vendored `ZIPFoundation` target. It is gated out
  of the Linux package graph under `#if os(macOS)`.
- **`RunPlayStudio`** — SwiftUI, Charts, app lifecycle, GUI state, and UI export.
- **`RunPlayCore` geodesy in production Swift** uses `GeoDistance` (pure Swift),
  not `CLLocation`; Core Location remains confined to platform/UI layers.

## What a future iOS product must validate

- Run the portable suites on iOS-derived toolchains: the strict engine build,
  `swift test --filter RunPlayEngineCppTests`, `RunPlayCoreTests`, native tests
  normal and `--sanitize`, and the boundary/AST validators.
- Confirm `RunPlayCore` still builds with the iOS SDK without importing
  `RunPlayPlatform` or `RunPlayStudio` (it must, by construction).
- Re-validate the Swift facade audit on the new platform: only
  `RunPlayCore/Sources/Interop/` imports `RunPlayEngineCpp`; no C++ type escapes
  into public `RunPlayCore` APIs; pointer buffers stay nonescaping within the
  synchronous native call.
- Keep C++ interop settings (`cxxInteropSettings`) in the package for the Core
  target and its tests, matching the macOS graph.
- Preserve cooperative cancellation: native calls are synchronous and
  non-callback; an iOS app must keep cancellation checks in Swift around each
  native call, never inside it.
- Do not add Apple frameworks to `RunPlayCore` or the engine to satisfy a new
  platform; extend `RunPlayPlatform` equivalents instead.
