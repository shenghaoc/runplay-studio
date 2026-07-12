# RunPlay Studio — Product

RunPlay Studio is a local-first, native macOS desktop app for post-run GPS workout analysis and replay. It is not a cloud service and has no backend, accounts, telemetry, or AI APIs.

## Core Value

Import completed runs (GPX, TCX, FIT, JSON) and explore them through:
- Apple Maps 2D/3D route replay with synchronized timeline controls
- Pace, elevation, heart rate, and speed charts with click-to-seek
- Automatic segment detection (fastest 400m/1km, slowest 1km, biggest climb/descent)
- Side-by-side route comparison with split breakdowns and a shared map
- Local export as JSON, CSV, or a PNG summary card

## Privacy Contract

Workout data is processed and stored entirely on the user's Mac (`Application Support/RunPlayStudio/`). The only outbound network traffic is Apple MapKit loading map tiles for the visible route region. No workout file data or metrics are sent anywhere by the app.

Never commit real workout data. Use `local-workouts/` or `private-workouts/` (gitignored) for personal files. All committed fixtures and demo assets must be synthetic or anonymized.

## Status

Active development. SwiftPM builds clean and the full test suite passes. HealthKit integration is a research placeholder, not yet functional.
