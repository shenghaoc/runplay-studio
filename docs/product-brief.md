# RunPlay Studio — Product Brief

## Why Desktop Matters

Mobile running apps are designed for the run. They show live metrics, GPS
tracking, and audio cues. But analyzing a completed run on a small phone screen
is cramped and limited.

A desktop studio offers:

- Large screen real estate for detailed route visualization
- Precise timeline scrubbing with mouse and trackpad
- Multi-panel layouts showing an Apple Maps route, charts, and splits simultaneously
- Keyboard shortcuts for power users
- Local processing power for complex route analysis

## Why Post-Run Analysis, Not Live Tracking

RunPlay Studio is explicitly for after the run. The user records with their
preferred device (Apple Watch, Garmin, any GPX/TCX/FIT source) and imports the
data for analysis on their Mac.

This means:

- No GPS permissions needed during runs
- No battery drain during workouts
- Works with data from any source that exports standard formats
- Focus on analysis quality, not real-time performance

## Why Apple Maps 2D/3D Route Replay

RunPlay Studio uses one native MapKit surface that toggles between a flat
top-down view and a pitched 3D perspective on the same route. This is not a
custom 3D renderer or a textured plane — it is Apple Maps with a camera pitch
control.

The pitched 3D view provides:

- Real terrain, buildings, and Apple Maps context
- Visible climbs, descents, and elevation changes on actual map data
- Familiar spatial orientation — runners recognize their routes on Apple Maps
- No custom geometry to maintain or rendering pipeline to debug

The 2D/3D toggle changes a single `MapCamera.pitch` value on one shared
`RouteMapCanvas`. Both presentations show the same route polyline, replay
marker, start/finish annotations, and map content.

## How This Differs

| Feature | Phone Apps | Web Apps | RunPlay Studio |
|---------|-----------|----------|----------------|
| Live tracking | ✅ | ✅ | ❌ intentionally |
| Apple Maps 2D/3D replay | ❌ | Limited | ✅ |
| Timeline scrubbing | Limited | Limited | ✅ |
| Split analysis | Basic | Basic | ✅ |
| Multi-panel view | ❌ | Limited | ✅ |
| Workout data local-only | ❌ | ❌ | ✅ |
| Desktop-optimized | ❌ | ❌ | ✅ |

## What RunPlay Studio Is Not

- Not a live run tracker
- Not a Strava clone
- Not a social network
- Not a generic fitness dashboard
- Not a web app
- Not an AI product
- Not a custom 3D globe or terrain renderer

## Target User

Runners who:

- Track runs with GPS devices or apps
- Want to analyze routes in detail after the run
- Care about elevation, splits, segment detection, and pacing
- Prefer desktop analysis over phone screens
- Value local-only data storage and no accounts
