# Portable Core iOS Readiness

This document records how much of the stack is platform-neutral today, where the
Apple-only boundaries sit, and what an iOS product would actually have to do.
It is a durable reference; `Package.swift` and the source conditions are
executable truth.

## Current state: the manifest declares macOS only

`Package.swift` declares exactly one platform:

```swift
platforms: [
    .macOS(.v26),
],
```

**There is no iOS platform declaration today, and no iOS build has ever been run
in CI.**

Read that declaration precisely: SwiftPM's `platforms` list sets *minimum
deployment versions* for the platforms named, not a whitelist of platforms the
package may be built for. Linux CI builds `RunPlayCore` and the consumer-smoke
package on every PR even though Linux is absent from the list, because an
unlisted platform simply carries no minimum-version constraint. So "declares
macOS only" is not the same claim as "runs only on macOS" — the Linux jobs are
standing proof of that.

What the missing `.iOS(...)` entry does affect is Apple tooling: Xcode and
`xcodebuild` consult this list when resolving a destination, so an iOS
destination is not selectable until the platform is declared.

Everything below describes portability of the *source*, which is a weaker claim
than a shipping build. The engine and Core have now been compiled and
typechecked against the iOS Simulator SDK with zero diagnostics, so
"platform-neutral" here is stronger than "avoids Apple-only APIs by
inspection" — but nothing has been linked, tested, or run on iOS. See
"iOS SDK build attempt" for exactly what was and was not demonstrated.

## What is platform-neutral in source

- **`RunPlayEngineCpp`** is portable C++23 using only the C++ standard library.
  No Apple framework, Foundation, Objective-C, or third-party dependency appears
  in the engine or its native tests. `scripts/validate-cpp-boundaries.sh` fails
  any engine source that imports an Apple framework, and the native tests build
  with plain `clang++` on macOS and Linux.
- **`RunPlayCore`** is cross-platform Swift: Foundation, a conditional
  `FoundationXML` import, and a single `canImport(Darwin)` guard
  (`Services/RouteMetricColorModels.swift`). It imports no UI, map, graphics,
  Core Location, or Combine. `RunPlayCore` plus its tests are the complete
  Swift-facing package graph on Linux, and Linux CI exercises them on every PR —
  which is the strongest existing evidence that Core is not macOS-bound.
- **Validators** (`validate-cpp-boundaries.sh`, `validate-cpp-public-ast.py`,
  `run-cpp-engine-tests.sh`) use `clang++`, `perl`, and `find`; nothing in them
  is macOS-specific.

### FoundationXML

`Importers/GPXImporter.swift` and `Importers/TCXImporter.swift` are the two
`XMLParser` consumers, and both carry the same guard:

```swift
#if canImport(FoundationXML)
import FoundationXML
#endif
```

On Darwin — macOS **and** iOS alike — `XMLParser` lives in Foundation, so
`canImport(FoundationXML)` is false and no extra import happens. The
swift-corelibs path is the one that needs the separate module. iOS therefore
needs no change here; it behaves exactly as macOS does today.

### Filesystem and import paths

`RunPlayCore` touches the filesystem in two distinct roles, and they carry
different iOS consequences.

**Read-only probes on a caller-supplied import path:**

- `Importers/WorkoutImporting.swift` — `fileExists(atPath:)`
- `Services/FITSessionImportService.swift` — `fileExists(atPath:isDirectory:)`
  and `attributesOfItem(atPath:)`

**A full read/write persistence store**, `Services/FileWorkoutLibraryStore.swift`,
which is not a probe: it calls `createDirectory(at:withIntermediateDirectories:)`,
`Data.write(to:options:.atomic)`, `removeItem(at:)`, and `moveItem(at:to:)` to
run a staging-then-promote workflow, and reads back through `Data(contentsOf:)`.
Its `FileManager` is injectable and defaults to `.default`.

Every one of these APIs exists on iOS, and the two roles need different work.

*Imports* are the case that does not transfer as written. The surrounding
assumption is a freely readable user-chosen path; iOS apps are sandboxed, so an
iOS product must adopt security-scoped bookmarks and
`startAccessingSecurityScopedResource()` around user-selected files, and route
imports through `UIDocumentPicker`/Files rather than an AppKit open panel. The
Core API shape (given a `URL`, import it) does not need to change; the caller
that produces the `URL` does.

*Library storage* is in better shape than it looks. The store never derives its
own location — `rootURL` is injected, and the only production caller chains
`RunPlayStudio/Sources/Views/ContentView.swift` (which resolves
`.applicationSupportDirectory` in `.userDomainMask`) into
`ViewModels/AppState.swift`. That search-path API resolves inside the app
container on iOS, so the derivation is already sandbox-shaped and the store
itself stays platform-neutral. Two things still need a deliberate decision
rather than an assumption:

- **Data Protection.** iOS encrypts container files by default, and under the
  default protection class they are unreadable while the device is locked. A
  store that may be written from the background needs its protection class
  chosen explicitly (commonly `.completeUntilFirstUserAuthentication`) instead
  of inheriting whatever the default is.
- **Backup policy.** Application Support is included in iCloud/iTunes backups by
  default. A re-importable workout library may want `isExcludedFromBackup` set;
  on macOS this has never had to be decided.

### Public model surface

The public `RunPlayCore` model layer is value-typed and already annotated for
concurrency and persistence: roughly 110 `Sendable`, 77 `Hashable`, and 55
`Codable` conformances across `RunPlayCore/Sources/Models/`. None of these
conformances depend on an Apple-only type, and no C++ type appears in a public
`RunPlayCore` API (enforced per header family by the boundary validator). No
iOS-specific work is expected here.

## Apple-only paths

- **`RunPlayPlatform`** — macOS non-UI adapters, gated out of the Linux graph
  under `#if os(macOS)`. Framework usage: `AppKit` (7 files), `SceneKit` (3),
  `MapKit` (3), `CoreGraphics` (2), plus `CryptoKit`, `zlib`, and the vendored
  `ZIPFoundation`.
- **`RunPlayStudio`** — SwiftUI, Charts, app lifecycle, GUI state, UI export.
- **`RunPlayCore` geodesy in production Swift** uses `GeoDistance` (pure Swift),
  not `CLLocation`; Core Location stays in platform/UI layers.

### What needs an iOS replacement

`SceneKit`, `MapKit`, `CryptoKit`, `zlib`, and `ZIPFoundation` are all available
on iOS. **`AppKit` is the real porting cost.** These seven files would need
UIKit equivalents:

| File | AppKit dependency |
|---|---|
| `3D/RouteSceneBuilder.swift` | `NSColor`/`NSImage` for scene materials |
| `3D/ComparisonSceneBuilder.swift` | same, for the comparison scene |
| `Services/RouteColoringService.swift` | `NSColor` route colouring |
| `Services/RouteMetricPalette.swift` | `NSColor` palette definitions |
| `Services/WorkoutMapSnapshotter.swift` | `NSImage` map snapshotting |
| `Services/WorkoutMapSnapshotModels.swift` | `NSImage` snapshot models |
| `Services/MapSnapshotOverlayComposer.swift` | `NSImage`/`NSGraphicsContext` overlay compositing |

The common shape is `NSColor` → `UIColor` and `NSImage` → `UIImage`, which is
usually handled with a small platform-colour/image typealias layer rather than
per-call-site conditionals. That is a `RunPlayPlatform` change; neither
`RunPlayCore` nor the engine is involved.

`RunPlayStudio` is SwiftUI already, but its macOS idioms (windows, menu
commands, `NSSavePanel`-based export) would need iOS navigation and share-sheet
equivalents.

## iOS SDK build attempt

One experiment was actually run, against the iOS Simulator SDK on an Apple
silicon host (Swift 6.4, iPhoneSimulator 27.0 SDK, triple
`arm64-apple-ios18.0-simulator`). It is recorded here because its *failure mode*
is the useful part.

**1. Whole-package SwiftPM build — fails at link, not at compile.**

```bash
swift build --target RunPlayCore \
  -Xswiftc -sdk -Xswiftc "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -Xswiftc -target -Xswiftc arm64-apple-ios18.0-simulator
```

The C++ sources compiled for iOS — the build produced
`ElevationProfile.o` "built for 'iOS-simulator'" — and then the link failed:

```text
ld: building for 'macOS', but linking in object file (…/ElevationProfile.o)
    built for 'iOS-simulator'
```

The linker was invoked with `-target arm64-apple-macos26.0` and the macOS SDK.
`-Xswiftc`/`-Xcc` reach the compiler but not the link step, whose platform
SwiftPM derives from the manifest's declared `platforms:`. **This is the
concrete reason the missing `.iOS(...)` entry matters:** per-invocation flags
cannot stand in for a declared platform. A real iOS build needs the platform
declared (or a Swift SDK / destination), not more flags.

**2. Direct compilation — the portable layers do build for iOS.**

Bypassing SwiftPM's link step isolates the question the manifest obscures.

- All **9** engine translation units under `RunPlayEngineCpp/Sources` compile
  clean for `arm64-apple-ios18.0-simulator` under the full CI warning set
  (`-Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Wshadow -Werror`).
- All **119** `RunPlayCore/Sources` Swift files pass `swiftc -typecheck` for the
  same triple in Swift 6 language mode with `-cxx-interoperability-mode=default`
  against the engine module map — **zero diagnostics**.

**3. Negative control.** Adding a file containing `import AppKit` to that same
typecheck fails with `error: no such module 'AppKit'`, so the clean result above
reflects genuine iOS compatibility rather than a vacuous configuration.

**What this does and does not establish.** It establishes that the engine and
Core compile against the iOS SDK today with no source changes. It does **not**
establish a working iOS build: nothing was linked, no test was executed, and no
code ran on a simulator or device. Treat it as evidence that the source is
portable and that the remaining work is packaging, not rewriting.

## What a future iOS product must still validate

- Add an `.iOS(...)` platform to `Package.swift` and confirm the SwiftPM graph
  resolves with `RunPlayPlatform`/`RunPlayStudio` gated appropriately — today
  their sources are guarded for Linux with `#if os(macOS)`, which would also
  exclude them on iOS and needs a deliberate decision rather than an accident.
- Run the portable suites against an iOS-derived toolchain: the strict engine
  build, `RunPlayEngineCppTests`, `RunPlayCoreTests`, the native tests normal and
  `--sanitize`, and the boundary/AST validators.
- Re-validate the Swift facade audit on the new platform: only
  `RunPlayCore/Sources/Interop/` imports `RunPlayEngineCpp`; no C++ type escapes
  into public `RunPlayCore` APIs; pointer buffers stay nonescaping within the
  synchronous native call.
- Keep the C++ interop setting (`cxxInteropSettings`) on the Core target and its
  tests, matching the macOS graph.
- Preserve cooperative cancellation: native calls are synchronous and
  non-callback, so cancellation checks must stay in Swift around each native
  call, never inside it.
- Adopt sandbox-appropriate file access (security-scoped bookmarks, document
  picker) for imports, and decide `FileWorkoutLibraryStore`'s Data Protection
  class and backup exclusion explicitly rather than inheriting iOS defaults.
- Do not add Apple frameworks to `RunPlayCore` or the engine to satisfy a new
  platform; extend `RunPlayPlatform` equivalents instead.
