# ElevationProfile C++23 Migration — Tasks

Checked boxes do not replace tests or benchmark evidence.

- [x] Preflight from `origin/main`; create worktree and branch
- [x] Kiro requirements/design/tasks
- [x] Public C++ header and bulk API
- [x] C++ multi-pass implementation (output-as-workspace, no route heap)
- [x] Native C++ tests
- [x] Swift Interop bridge
- [x] Production `ElevationProfile.build` cutover
- [x] Independent Swift oracle
- [x] Bridge parity (including 1,000 fixtures)
- [x] Production parity tests
- [x] AST and boundary validation updates
- [x] AGENTS / architecture / phase-plan documentation
- [x] Release benchmark script and measurements
- [x] Full Core/Platform/Studio verification
- [x] Post-cutover analysis profile
- [x] Draft PR with evidence

## Post-cutover decision

- Route-metric scale/bucket work is the next performance candidate if the
  product-limit map-coloring path warrants another optimization phase.
- MovementProfile remains in Swift: the refreshed product-limit analysis share
  is too small to justify a native migration ahead of route metrics or cleanup.
- Final portable-core cleanup remains mandatory.

## Explicit non-goals

- MovementProfile migration
- WorkoutTimeline migration
- Route-metric migration
- Schema / analysis-version changes
