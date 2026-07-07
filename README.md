# RunPlay Studio

A native macOS post-run 2D/3D route replay and analysis app for runners.

![RunPlay Studio summary export — generated from bundled synthetic demo data](docs/assets/demo-summary.png)

*Screenshot generated from bundled synthetic demo data — no private workout data used.*

## What It Is

RunPlay Studio is a local-first desktop replay studio for GPS running workouts. Import completed runs from GPX, TCX, FIT, or JSON files and explore them with an Apple Maps 2D/3D route view, synchronized charts, split analysis, and segment highlights.

---

## Highlights

- **Apple Maps 2D/3D replay** — One route map with a native pitch toggle and synchronized timeline controls
- **Synchronized views** — Map, charts, and split table stay in sync with the timeline
- **Route comparison** — Summary deltas, pace chart, and a shared 2D/3D Apple Maps overlay
- **Segment detection** — Auto-identify fastest 400m, fastest 1km, slowest 1km, biggest climb/descent
- **Chart click/drag to seek** — Click or drag on charts to navigate the run
- **Local-only privacy** — No app-operated cloud backend, account, telemetry, analytics, or AI API

---

## Supported Formats

### Import

| Format | Status | Notes |
|--------|--------|-------|
| JSON   | ✅ Full support | Native format, all fields supported |
| GPX    | ✅ Track support | Requires at least one timestamp; partial missing timestamps are interpolated; HR/cadence via extensions |
| TCX    | ✅ Full support | Training Center XML with laps, HR, cadence, distance; partial missing timestamps are interpolated |
| FIT    | ✅ Basic support | Binary format with GPS, altitude, HR, cadence; requires at least one timestamp; see limitations below |
| HealthKit | 📋 Research only | Requires entitlements, future work |

**File picker**: the macOS open panel allows generic file data so `.json`, `.gpx`, `.tcx`, and `.fit` files can be selected in the Swift Package app path. Unsupported extensions are rejected by importer validation with a clear error message.

### Export

| Format | Description |
|--------|-------------|
| JSON   | Complete workout summary with splits and segments |
| CSV    | Splits, segments, or combined data |
| PNG    | Polished summary card (1200×1600) |

---

## Privacy

RunPlay Studio is a **local-only** application:

- **Local workout processing** — Workout data is processed on your Mac. Imported files remain at their original locations, and exported files remain where you save them.
- **No app-operated cloud, accounts, or telemetry** — The app has no backend service, sign-up/login, usage tracking, or phone-home behavior.
- **No AI APIs** — No external AI services are used.
- **MapKit map content** — Apple MapKit loads map content from Apple services over the network. Requests cover the map region derived from your route coordinates, so the general area of your route is visible to Apple Maps. No workout file data or metrics are sent by the app.

For manual dogfooding with real workouts, keep private files in ignored local
paths and follow [docs/private-data.md](docs/private-data.md). Public fixtures
and demo assets must be synthetic or anonymized.

---

## Demo

See [docs/demo-script.md](docs/demo-script.md) for a 3–5 minute walkthrough using bundled synthetic data.

See [docs/release-notes/v0.1.0-demo.md](docs/release-notes/v0.1.0-demo.md) for the v0.1 demo release.

---

## Current Status

SwiftPM builds and the full test suite passes. GUI verification notes are kept in
`docs/manual-testing.md`.

| Check | Status |
|-------|--------|
| `swift build` | ✅ Pass |
| `swift test` | ✅ Pass |
| Core tests (`swift test --filter RunPlayCoreTests`) | ✅ Pass (114 tests, platform-neutral) |
| CI | ✅ GitHub Actions macOS + Linux (Core) |
| Manual GUI verification | See `docs/manual-testing.md` |

### Core Testability

The `RunPlayCore` target is a platform-neutral Swift library with no Apple UI framework dependencies:

```bash
# Build core library only
swift build --target RunPlayCore

# Run core tests only (no macOS UI frameworks required)
swift test --filter RunPlayCoreTests
```

See [AGENTS.md](AGENTS.md) for detailed architecture and testing guidance.

---

## Build Requirements

- macOS 14.0+
- Xcode 15.0+ (for SwiftUI features)
- Swift 5.9+

## How to Build

This is a **Swift Package** (no `.xcodeproj` file). Xcode can open Swift Packages directly.

### Command Line

```bash
# Clone the repo
git clone https://github.com/shenghaoc/runplay-studio.git
cd runplay-studio

# Build
swift build

# Run tests
swift test
```

### Xcode

```bash
# Open the package in Xcode
open Package.swift
```

Xcode will open the Swift Package and resolve dependencies. To run:
1. Select the **RunPlayStudio** scheme in the toolbar
2. Choose **My Mac** as the destination
3. Press **⌘R** to build and run

The app will launch with two bundled sample runs pre-loaded so comparison mode can be tried immediately. Import additional runs via the sidebar import button (supports JSON, GPX, TCX, and FIT files).

### Xcode vs Swift Package

| Approach | Use Case |
|----------|----------|
| `open Package.swift` | Development, UI work, debugging |
| `swift build` / `swift test` | CI, headless verification, scripting |

Both approaches use the same source code. There is no separate Xcode project file to maintain.

---

## App Features

### Apple Maps 2D/3D Route Replay (MapKit for SwiftUI)

RunPlay Studio uses one SwiftUI `Map` for both presentations. One in-map
2D/3D control changes the same route map between a flat overhead view and a
pitched 3D perspective; it does not switch to a custom SceneKit world.

**What you see:**
- Apple Maps roads, labels, points of interest, terrain, and buildings
- Blue route polyline with start, finish, and replay-position annotations
- Top-down 2D and realistic-elevation pitched 3D on the same map
- The same route overlays and replay state in both modes

**Controls:**
- **2D/3D** — One in-map toggle bound to the MapKit camera pitch
- **Pan/rotate/zoom** — Standard Apple Maps interactions
- **Fit Route** — Reframes the route without changing to another view
- **Zoom stepper** — Native MapKit zoom control

### Overview (Default)
- Map with route overlay as the default landing view
- Run summary metrics and replay controls
- Real map context via Apple MapKit (loads map tiles from Apple services)

### Map View (MapKit)
- One route map with flat 2D and realistic 3D modes
- Start/finish annotations
- Full-screen map for detailed route inspection

### Charts (Swift Charts)
- Pace, elevation, heart rate, and speed over distance
- Interactive scrubbing synced to replay
- Heart-rate chart shows an explicit no-data state when usable HR samples are unavailable

### Split Analysis
- Automatic kilometer splits
- Per-split pace, elevation gain, heart rate
- Fastest/slowest segment highlighting
- Current split highlighted during replay

### Synchronized Replay
All views stay in sync with the replay position:
- Map route marker updates with the timeline in both 2D and 3D
- Charts show selection indicator at current distance
- **Chart click/drag to seek** — drag on charts to navigate the run
- Current metrics panel shows real-time data
- Split table highlights current split
- Timeline slider drives all views

Chart drag behavior: dragging on any chart pauses playback and seeks to the selected position. Visual feedback shows an orange indicator during drag.

### Segment Detection
Automatically identifies key run segments:
- Fastest 400m
- Fastest 1km
- Slowest 1km
- Biggest climb
- Biggest descent

Segments are detected using distance-based sliding windows for accuracy with uneven GPS sampling. Selecting a segment highlights it in 3D and seeks the replay to its start.

### Export
Export workout data as local files:
- **JSON Summary** — Complete workout data with splits and segments
- **Splits CSV** — Kilometer splits with pace, elevation, heart rate
- **Segments CSV** — Detected segments with metrics
- **Combined CSV** — Splits and segments in one file
- **PNG Summary Card** — Polished stats card image (1200×1600)

All exports are local-only. No data is uploaded anywhere.
PNG export renders a SwiftUI card using NSHostingView (requires GUI context).
The README demo image is generated from bundled synthetic data.

### Route Comparison

Compare two completed runs side by side:

- Summary deltas for distance, duration, pace, elevation, and heart rate
- Per-split comparison table with pace, delta, and winner columns
- Pace over distance chart with actual workout names in the legend
- One comparison map whose native pitch toggle switches both route overlays
  between 2D and 3D
- Distance slider to scrub along the common route and see where both runners
  were at each point, with elapsed time and pace delta readout
- Warnings for different distances, route shapes, and missing data

---

## Limitations

- Comparison is distance-aligned only — no dynamic time warping or route matching
- FIT support is basic — CRC validation is not implemented; compressed timestamp headers fail with a controlled unsupported-data error; only record messages (global message 20) are parsed; signed coordinate decoding uses bit-pattern semantics for western/southern hemispheres
- No HealthKit integration (placeholder importer exists but is not yet functional)
- No cloud sync, accounts, or web interface
- macOS only (requires SwiftUI and MapKit)
- PNG export requires GUI context (NSHostingView)

## Roadmap

See [docs/phase-plan.md](docs/phase-plan.md) for detailed development phases.

## License

MIT License — see [LICENSE](LICENSE)
