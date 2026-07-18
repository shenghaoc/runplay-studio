# Tasks: Personal Route Heatmap

- [x] Add Core models, validated configuration, projected grid, deterministic
  distinct-workout aggregation, adaptive coarsening, diagnostics, and
  cancellation.
- [x] Preserve discontinuities from route segments, malformed long intervals,
  and discarded invalid coordinates; retain isolated valid coverage points.
- [x] Add `RouteMapArea` conversion and shared area-aware map fitting/camera
  planning in the Platform layer.
- [x] Add the heatmap view model, native sidebar/menu navigation, filter UI,
  status states, legend, and reusable map-area rendering in Studio.
- [x] Keep workspace transitions, deletion behavior, cache invalidation,
  relative clock handling, and cancellation covered by focused tests.
- [x] Document the architecture, derived-data policy, privacy behavior, and
  manual verification checklist without claiming unperformed interactive tests.
- [ ] Perform the synthetic-workout, keyboard/VoiceOver, MapKit appearance, and
  full workspace-flow checks in `docs/manual-testing.md` on an interactive Mac.
