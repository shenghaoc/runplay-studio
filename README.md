# RunPlay Studio

A native macOS post-run 2D/3D route replay and analysis app for runners.

![RunPlay Studio summary export — generated from bundled synthetic demo data](docs/assets/demo-summary.png)

*Screenshot generated from bundled synthetic demo data — no private workout data used.*

## What It Is

RunPlay Studio is a local-first desktop replay studio for GPS running workouts. Import completed runs from GPX, TCX, FIT, or JSON files and explore them with an Apple Maps 2D/3D route view, synchronized charts, calculated kilometre splits, source-recorded laps, and segment highlights.

Time labels are pause-aware: **Elapsed** includes recording gaps, **Active**
excludes gaps between continuous route segments, and **Pace** uses active time.
**Moving** and **Stopped** are conservative GPS-derived estimates within active
time: `active = moving + stopped`. Uncertain active intervals count as moving;
explicit pauses remain paused and are never inferred as stops. **Moving Pace
(est.)** is separate—canonical **Pace** remains active-time based. Sparse or
irregular timing falls back safely to `moving = active`, `stopped = 0`.

---

## Highlights

- **Apple Maps 2D/3D replay** — One route map with a native pitch toggle and synchronized timeline controls
- **Route metric coloring** — Color the single-workout map by solid, relative pace, relative heart rate, or corrected elevation (not HR zones; comparison and heatmap palettes stay separate)
- **Personal heatmap** — Local density map of places you run most often across the workout library (distinct workouts per cell, not GPS sample density)
- **All Runs library** — Search, filter, sort, favourite, tag, and rename runs; save smart collections as dynamic queries; the sidebar shows bounded Favourites, Recent, and Smart Collections instead of every workout
- **Synchronized views** — Map and charts stay in sync with the timeline
- **Route comparison** — Distance or Route-Aware (constrained DTW) alignment, elapsed/active deltas, active-pace chart, and a shared 2D/3D Apple Maps overlay
- **Segment detection** — Auto-identify active-pace fastest/slowest windows and biggest climb/descent
- **Native session restoration** — One coordinated macOS window restores bounded logical workspace state on relaunch without restoring transient UI; macOS separately owns frame and display placement
- **Chart click/drag to seek** — Click or drag on charts to navigate the run; keyboard Jump to distance and VoiceOver seek actions provide non-pointer equivalents
- **Keyboard and VoiceOver** — Native menus for File, Workout, Replay, Library, View, and Help → Keyboard Shortcuts; chart descriptors, map summaries, and deliberate announcements without 30 fps spam
- **Local-only privacy** — No app-operated cloud backend, account, telemetry, analytics, or AI API
- **Strava bulk archive import** — Import running activities from a local Strava export ZIP (no login or network)
- **Multi-session FIT import** — Review every session in a multi-session `.fit` file and import the supported runs as separate workouts in one transaction

---

## Supported Formats

### Import

| Format | Status | Notes |
|--------|--------|-------|
| JSON   | ✅ Full support | Native format, all fields supported |
| GPX    | ✅ Track support | Requires at least one timestamp; partial missing timestamps are interpolated; HR/cadence via extensions |
| TCX    | ✅ Full support | Training Center XML with recorded-lap summaries, HR, cadence, distance; seamless laps stay continuous; partial missing timestamps are interpolated |
| FIT    | ✅ Common running activities | CRC-validated binary activity files with compressed timestamps, session selection, multi-session review and batch import, recorded-lap preservation, pause/resume boundaries, and enhanced metrics; see limitations below |
| HealthKit | 📋 Research only | Requires entitlements, future work |

**File picker**: the macOS open panel allows generic file data so `.json`, `.gpx`, `.tcx`, and `.fit` files can be selected in the Swift Package app path. Unsupported extensions are rejected by importer validation with a clear error message.

### Export

| Format | Description |
|--------|-------------|
| JSON   | Explicit elapsed, active, paused, moving/stopped estimates, pace, diagnostics, splits, and segments |
| CSV    | Splits and segments with explicit clock and pace columns; estimated moving/stopped labels |
| PNG    | Configurable summary card (exact 1200×1600 px): optional map, Light/Dark, route colors |

---

## Privacy

RunPlay Studio is a **local-only** application:

- **Local workout processing** — Workout data is processed on your Mac. Imported workouts are stored locally in the app's `Application Support/RunPlayStudio/` directory. The original imported file is not modified; the normalized workout snapshot remains available even if the original file is moved or deleted.
- **No app-operated cloud, accounts, or telemetry** — The app has no backend service, sign-up/login, usage tracking, or phone-home behavior.
- **No AI APIs** — No external AI services are used.
- **MapKit map content** — Apple MapKit loads map content from Apple services over the network. Requests cover the map region derived from your route coordinates, so the general area of your route is visible to Apple Maps. No workout file data or metrics are sent by the app.
- **Deleting a workout** removes the stored library copy, not the original imported file.

For manual dogfooding with real workouts, keep private files in ignored local
paths and follow [docs/private-data.md](docs/private-data.md). Public fixtures
and demo assets must be synthetic or anonymized.

## Application session restoration

RunPlay Studio uses one app-owned main window and one app-owned `AppState` for
the coordinated workspace. macOS owns native window frame restoration; the
app supplies a display-aware default near 1200×800 only when no restorable
frame exists.

The separate Studio session file restores the visible workout, All Runs or
smart-collection query context, Personal Heatmap filters, comparison pair, alignment mode,
distance, workout tab/map presentation, replay position and speed, and sidebar
visibility. The library manifest remains authoritative for workout order,
selected workout, favourites, tags, assignments, and smart collections.
Replay always returns paused. Import/export sheets, alerts, editors, map/cache
data, table selections, query results, and in-progress operations are never
restored. Missing or corrupt session data falls back to the manifest-selected
workout and safe defaults. The packaged-app checklist in
[`docs/manual-testing.md`](docs/manual-testing.md) records the desktop flows
actually exercised; secondary-display placement requires matching hardware.

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
| Core tests (`swift test --filter RunPlayCoreTests`) | ✅ Pass (platform-neutral) |
| CI | ✅ GitHub Actions macOS + Linux (Core) |
| Manual GUI verification | See `docs/manual-testing.md` |

### Core Testability

The `RunPlayCore` target is a platform-neutral Swift library with no Apple UI framework dependencies. It depends on the portable `RunPlayEngineCpp` C++23 foundation target (smoke API only; no production algorithms migrated yet):

```bash
# Build portable C++ engine foundation
swift build --target RunPlayEngineCpp

# Run native C++ engine tests through the portable SwiftPM harness
swift test --filter RunPlayEngineCppTests -Xswiftc -warnings-as-errors

# Run the same native C++ executable directly
./scripts/run-cpp-engine-tests.sh

# ASan + UBSan on the native C++ test binary
./scripts/run-cpp-engine-tests.sh --sanitize

# Architecture-boundary validation for the C++ engine
./scripts/validate-cpp-boundaries.sh

# Build core library (includes Swift/C++ interop adapter)
swift build --target RunPlayCore

# Run core tests only (includes Swift integration tests for the engine adapter)
swift test --filter RunPlayCoreTests
```

See [AGENTS.md](AGENTS.md) for repository and agent-working rules, and
[docs/architecture.md](docs/architecture.md) for detailed architecture and
testing guidance.

---

## Build Requirements

- macOS 26.0+
- Xcode 26.4+ (for the Swift 6.3 toolchain)
- Swift 6.3+

---

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

## CI and Demo Packaging

### GitHub Actions CI

Every push to `main` and every pull request runs:

- **macOS** — C++ engine build + native C++ tests + boundary validation + full `swift test`
- **Linux** — C++ engine build + native C++ tests + boundary validation + `swift test --filter RunPlayCoreTests`
- **Linux sanitizers** — native C++ tests under AddressSanitizer and UndefinedBehaviorSanitizer

Test counts are reported in the GitHub Actions step summary.

### Demo App Artifact

A manually-triggered **Package Demo** workflow (`.github/workflows/package-demo.yml`) builds an unsigned `.app` bundle and uploads it as a GitHub Actions artifact.

To trigger it: go to **Actions → Package Demo → Run workflow**.

GitHub downloads the artifact as an outer archive containing
`RunPlayStudio.app.zip`. Unzip the downloaded archive, then unzip
`RunPlayStudio.app.zip` and double-click the app to run it.

#### Packaging Limitations

| Limitation | Detail |
|------------|--------|
| **Unsigned** | The app is not code-signed. macOS Gatekeeper will block it by default. Right-click → Open to bypass. |
| **Not notarized** | The app has not been submitted to Apple for notarization. |
| **Debug resources only** | The bundle includes sample runs from `RunPlayStudio/Resources/` for demo purposes. |
| **arm64 only** | Built for Apple Silicon. Intel Macs are not supported. |
| **For demo/testing only** | This artifact is intended for evaluation, not production use. |

To build a local `.app` bundle:

```bash
./scripts/package-demo.sh
# Output: .build/artifacts/RunPlayStudio.app
```

## Supported Import Formats

| Format | Status | Notes |
|--------|--------|-------|
| JSON   | ✅ Full support | Native format, all fields supported |
| GPX    | ✅ Track support | Requires at least one timestamp for elapsed/active pace analysis; partial missing timestamps are interpolated; normalized elapsed values are used when timestamps do not span; HR/cadence via extensions |
| TCX    | ✅ Full support | Training Center XML with recorded-lap summaries, HR, cadence, distance; seamless laps stay continuous; partial missing timestamps are interpolated |
| FIT    | ✅ Common running activities | CRC-validated binary activity files with compressed timestamps, session selection, multi-session review and batch import, recorded-lap preservation, pause/resume boundaries, and enhanced metrics; see limitations below |
| HealthKit | 📋 Research only | Requires entitlements, future work |

**File picker**: the macOS open panel allows generic file data so `.json`, `.gpx`, `.tcx`, and `.fit` files can be selected in the Swift Package app path. Unsupported extensions are rejected by importer validation with a clear error message.

**FIT scope**: Common running activity files validate header and file CRCs, decode compressed timestamps, and retain standard file-ID, record, event, lap, session, activity, and device-info messages in source order. A file with zero or one session message imports directly; a file with several session messages opens the **Import FIT Sessions** review sheet, where supported running sessions become separate workouts committed in one transaction. Timer boundaries preserve route gaps, and supplied distance is used per valid segment. Developer metrics, component accumulation, unsupported subfields, and course/workout files remain unsupported.

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
- Run summary metrics for Distance, Elapsed, Active, and active Pace
- Replay controls whose total duration is elapsed time
- Real map context via Apple MapKit (loads map tiles from Apple services)

### Map View (MapKit)
- One route map with flat 2D and realistic 3D modes
- Start/finish annotations
- Full-screen map for detailed route inspection

### Charts (Swift Charts)
- Pace, elevation, heart rate, and speed over distance
- Interactive scrubbing synced to replay
- Heart-rate chart shows an explicit no-data state when usable HR samples are unavailable

### Split and Recorded-Lap Analysis
- Automatic global kilometre **calculated splits** that continue through pauses
- **Recorded laps** preserved from FIT lap messages and TCX `<Lap>` summaries (triggers, source totals, route-derived clocks)
- Splits workspace mode selector: Distance Splits vs Recorded Laps when source laps exist
- Per-split/lap elapsed, active, moving/stopped estimates, pace, elevation, and heart rate
- Current calculated split and recorded lap highlighted during replay; seek to lap start
- Fastest/slowest segment highlighting

### Synchronized Replay
All views stay in sync with the replay position:
- Map route marker updates with the timeline in both 2D and 3D
- Charts show selection indicator at current distance
- **Chart click/drag to seek** — drag on charts to navigate the run
- Current metrics panel shows real-time data
- Timeline slider drives all views

Replay runs on elapsed time. During a recording gap its clock advances while
the marker, distance, and active time hold at the pre-pause endpoint; the marker
jumps to the real resume point only at the resume timestamp.

Chart drag behavior: dragging on any chart pauses playback and seeks to the selected position. Visual feedback shows an orange indicator during drag.

### Segment Detection
Automatically identifies key run segments:
- Fastest 400m
- Fastest 1km
- Slowest 1km
- Biggest climb
- Biggest descent

Segments are detected using distance-based sliding windows and active time for
pace. Windows may continue across a pause in cumulative distance, while
elevation and geographic interpolation never bridge the gap. Selecting a
segment highlights it in 3D and seeks the replay to its start.

### Export
Export workout data as local files:
- **JSON Summary** — Elapsed, active, paused, active/elapsed pace, calculated splits, recorded laps, and segments
- **Distance Splits CSV** — Explicit elapsed/active duration and pace columns, elevation, and heart rate
- **Recorded Laps CSV** — Source triggers, route-derived clocks, and source-reported totals (distinct from splits)
- **Segments CSV** — Active duration/pace with elapsed endpoints and metrics
- **Combined CSV** — Splits and segments in one file
- **PNG Summary Card** — Exact 1200×1600 pixel summary image with optional static Apple Maps region, Light/Dark appearance, and Solid/Pace/HR/Elevation route coloring (reuses live-map builders)

All exports are local-only. No data is uploaded to a RunPlay Studio service.
PNG export opens a configuration sheet, generates a deterministic card with
`ImageRenderer` at scale 1.0 (GUI context required), and optionally composites
MapKit basemap imagery with custom route overlays. Map failure offers Retry or
Export Without Map. No Screen Recording permission is required.
The README demo image is generated from bundled synthetic data.

### Route Comparison

Compare two completed runs side by side:

- Alignment modes: **Distance** (equal cumulative distance) and **Route-Aware**
  (constrained dynamic time warping over GPS route shape)
- Summary deltas for distance, Active Time, Elapsed Time, paused time, active pace, elevation, and heart rate (whole-workout; independent of alignment mode)
- Per-split and recorded-lap tables remain distance/ordinal, not DTW-aligned
- Active pace chart over distance or matched route progress
- One comparison map whose native pitch toggle switches both route overlays
  between 2D and 3D
- Distance or matched-route slider with elapsed/active/pace deltas
- Route-Aware quality panel, opposite-direction / low-coverage fallbacks
- Warnings for different pause durations, distances, route shapes, and missing data

---

## Limitations

- Route-Aware alignment is GPS shape matching, not road-level map matching or survey-grade geometry
- Opposite-direction runs and large cyclic start rotations are unavailable or limited in Route-Aware mode
- Moving-time estimation remains an estimate; Active is recorded time inside continuous route segments
- FIT support targets common running activities rather than the full FIT profile; developer metrics, component accumulation, unsupported subfields, and course/workout files remain unsupported
- A Strava archive entry that itself contains several running sessions is reported as unsupported rather than opening a nested review sheet
- No HealthKit integration (placeholder importer exists but is not yet functional)
- No cloud sync, accounts, or web interface
- macOS only (requires SwiftUI and MapKit)
- PNG export requires GUI context (`ImageRenderer`); map-inclusive export needs MapKit network access for basemap tiles
- Video export is not implemented

## Roadmap

See [docs/phase-plan.md](docs/phase-plan.md) for detailed development phases.

---

## License

MIT License — see [LICENSE](LICENSE)
