# Tasks: C++23 Geodesy Primitives

Checked boxes record intent, not proof. Tests and CI are the evidence.

- [x] Add `Geodesy.hpp` with `earth_radius_meters`, `LocalMeters`, and three
  `[[nodiscard]] noexcept` declarations; include it from the engine umbrella
  header
- [x] Implement `Geodesy.cpp` with a private `degrees_to_radians` helper,
  preserving the Swift operation order and splitting statements so no
  multiply-add can be contracted
- [x] Add native C++ coordinate-validation tests (inclusive boundaries, signed
  zero, just-outside values, NaN and both infinities in each field)
- [x] Add native C++ distance tests against published reference ranges,
  covering identity, symmetry, degree scales, city pairs, antimeridian, pole
  boundaries, antipodal and near-antipodal pairs, tiny deltas, and invalid
  inputs returning positive zero
- [x] Add native C++ projection tests covering the centre, all four directions,
  axis isolation, equatorial/Singapore/high-latitude centres, non-finite
  propagation, and the absence of validation, clamping, and longitude wrapping
- [x] Assert the preserved exactly-antipodal NaN limitation in both the native
  and Swift parity suites instead of hiding it
- [x] Add compile-time `noexcept` and `LocalMeters` layout assertions
- [x] Wire `run_geodesy_tests` through `TestSupport.hpp` and `TestMain.cpp`,
  preserving the success marker
- [x] Add the internal parity-only `RunPlayGeodesyBridge` adapter returning a
  pure Swift `RunPlayLocalMeters`
- [x] Add Swift parity tests using `GeoDistance` as the oracle over
  deterministic fixtures with a documented tolerance and non-finite
  classification comparison
- [x] Extend `validate-cpp-public-ast.py` with positional-type rejection,
  geodesy self-test fixtures, and geodesy adversarial cases
- [x] Extend `validate-cpp-boundaries.sh` to enforce production isolation of the
  parity-only adapter mechanically
- [x] Confirm the native runner and sanitizer build compile `Geodesy.cpp` and
  `GeodesyTests.cpp` without script or manifest changes
- [x] Update AGENTS.md, README, architecture, and phase-plan docs to the exact
  new state with explicit non-goals
- [x] Run the warning-clean verification matrix recorded in the PR body

## Out of scope for this branch

- [ ] Migrate a complete route-processing slice into C++ behind one bulk call
  and consume these primitives internally (next PR)
