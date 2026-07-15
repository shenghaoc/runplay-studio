# Implementation Tasks

- [x] Add policy, movement state, diagnostics, and an immutable movement profile
  derived from normalized points and `WorkoutTimeline`.
- [x] Apply conservative geometry-first detection with hysteresis, dwell,
  resume distance, reliability fallback, and cooperative cancellation.
- [x] Carry the profile through shared analysis, summary, splits, replay,
  comparison, persistence migration, and exports.
- [x] Interpolate estimated clocks for partial split and comparison distances
  while preserving duplicate-distance boundary semantics.
- [x] Add focused estimated-time UI, help, localization, and VoiceOver labels
  without changing active-time pace terminology.
- [x] Add regression coverage for invariants, one-second sampling, fallback,
  split/comparison interpolation, persistence, and exports.
- [x] Update durable product and architecture documentation plus this PR spec.
- [ ] Complete the manual moving/stopped GUI checklist in
  `docs/manual-testing.md` in a desktop session; it is deliberately not claimed
  by automated verification.
