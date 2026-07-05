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

## Current MVP Status

**In Development** — Building core features incrementally.

### Working

- Data models for workouts, route points, splits
- JSON workout importer
- GPX importer (basic)
- Workout analysis (distance, pace, elevation, splits)
- Route projection (lat/lng → local 3D coordinates)
- 3D route visualization with SceneKit
- 2D MapKit route display
- Swift Charts for pace, elevation, heart rate
- Replay controller with timeline scrubbing
- macOS SwiftUI app shell with sidebar

### Stubbed / Future

- TCX importer (scaffold)
- FIT importer (placeholder)
- HealthKit importer (research needed)
- Route coloring by pace/heart rate in 3D
- Segment detection
- Video/PNG export
- Route comparison

## Build Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

## How to Build

```bash
open RunPlayStudio.xcodeproj
# or
swift build
```

## Supported Import Formats

| Format | Status |
|--------|--------|
| JSON   | ✅ Full support |
| GPX    | ✅ Basic support |
| TCX    | 🔧 Scaffold |
| FIT    | 📋 Placeholder |

## 3D Route Visualization

RunPlay Studio uses SceneKit to render a stylized 3D route scene:

- Route points converted to local meter-space coordinates
- Elevation used as Y-axis with configurable exaggeration
- Start/finish markers and optional kilometer markers
- Moving replay marker synced to timeline
- Orbit, pan, and zoom camera controls
- Ground grid for spatial reference

This is NOT a 3D globe or satellite terrain — it's a focused route visualization designed for post-run analysis.

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
