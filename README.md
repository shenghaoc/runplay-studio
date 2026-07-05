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

**✅ Verified Buildable** — Swift Package builds and all tests pass.

| Check | Status |
|-------|--------|
| `swift package describe` | ✅ Pass |
| `swift build` | ✅ Pass |
| `swift test` | ✅ Pass (33 tests) |
| CI | ✅ GitHub Actions macOS workflow |

## Build Requirements

- macOS 14.0+
- Xcode 15.0+ (for SwiftUI features)
- Swift 5.9+

## How to Build

This is a **Swift Package** (no Xcode project yet).

```bash
# Clone the repo
git clone https://github.com/shenghaoc/runplay-studio.git
cd runplay-studio

# Build
swift build

# Run tests
swift test
```

To open in Xcode:
```bash
open Package.swift
```
Xcode will open the package and you can build/run from there.

## Supported Import Formats

| Format | Status |
|--------|--------|
| JSON   | ✅ Full support |
| GPX    | ✅ Full support |
| TCX    | 🔧 Scaffold only |
| FIT    | 📋 Placeholder only |

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
