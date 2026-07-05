# RunPlay Studio

A native macOS post-run visualization studio for completed runs.

## What It Is

RunPlay Studio is a local-first desktop replay studio for GPS running workouts. Import completed runs from GPX, TCX, FIT, or JSON files and explore them with 3D route replay, synchronized charts, split analysis, and segment highlights.

## What It Is NOT

- A live run tracker
- A Strava clone
- A social network
- A generic fitness dashboard
- A web app
- An AI product

## Current Status

**✅ Verified Launchable** — Swift Package builds, tests pass, app launches with sample data.

| Check | Status |
|-------|--------|
| `swift package describe` | ✅ Pass |
| `swift build` | ✅ Pass |
| `swift test` | ✅ Pass (44 tests) |
| CI | ✅ GitHub Actions macOS workflow |
| Xcode launch | ✅ Opens via `open Package.swift` |
| Sample data loads | ✅ Bundled JSON auto-loads |
| GPX import | ✅ Tested with synthetic fixture |

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

The app will launch with a bundled sample run pre-loaded. Import additional runs via the sidebar import button (supports JSON and GPX files).

### Xcode vs Swift Package

| Approach | Use Case |
|----------|----------|
| `open Package.swift` | Development, UI work, debugging |
| `swift build` / `swift test` | CI, headless verification, scripting |

Both approaches use the same source code. There is no separate Xcode project file to maintain.

## Supported Import Formats

| Format | Status | Notes |
|--------|--------|-------|
| JSON   | ✅ Full support | Native format, all fields supported |
| GPX    | ✅ Basic support | Trackpoints with lat/lon/elevation/time; HR/cadence via extensions |
| TCX    | 🔧 Scaffold only | Parser not implemented |
| FIT    | 📋 Placeholder only | Binary format, future work |
| HealthKit | 📋 Research only | Requires entitlements, future work |

## App Features

### 3D Route Visualization (SceneKit)
- Route points converted to local meter-space coordinates
- Elevation used as Y-axis with configurable exaggeration
- Start/finish markers and optional kilometer markers
- Moving replay marker synced to timeline
- Orbit, pan, and zoom camera controls
- Ground grid for spatial reference

### Map View (MapKit)
- 2D overhead route display
- Start/finish annotations
- Reference context for the 3D view

### Charts (Swift Charts)
- Pace, elevation, heart rate over time
- Interactive scrubbing synced to replay

### Split Analysis
- Automatic kilometer splits
- Per-split pace, elevation gain, heart rate
- Fastest/slowest segment highlighting

## Privacy

- **Local-only** — All data stays on your Mac
- **No cloud** — No external servers or sync
- **No analytics** — No usage tracking
- **No telemetry** — No phone-home behavior
- **No account** — No sign-up or login
- **No AI API** — No external AI services

## Roadmap

See [docs/phase-plan.md](docs/phase-plan.md) for detailed development phases.

## License

MIT License — see [LICENSE](LICENSE)
