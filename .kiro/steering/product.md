---
inclusion: always
---

# RunPlay Studio product context

RunPlay Studio is a native macOS application for local, post-run GPS workout
visualization, replay, analysis, comparison, personal route heatmap, and export.

Core product invariants:

- Completed workouts are recorded elsewhere and analyzed afterward on the Mac.
- Workout processing and persistence remain local to the user's Mac.
- The app has no account system, app-operated backend, telemetry, analytics, or
  embedded AI API.
- Committed workouts, fixtures, exports, and screenshots must be synthetic or
  anonymized.

Repository policy: #[[file:AGENTS.md]]
Product reference: #[[file:README.md]]
Privacy reference: #[[file:docs/private-data.md]]
