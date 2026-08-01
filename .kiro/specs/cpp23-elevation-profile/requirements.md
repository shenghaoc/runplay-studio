# ElevationProfile C++23 Migration — Requirements

## Objective

Move the complete route-wide `ElevationProfile.build` computational pipeline
into one allocation-free C++23 bulk call while preserving all existing public
Swift models and query behavior.

## Scope

- The entire multi-pass elevation build migrates together:
  1. source-altitude plausibility screening
  2. endpoint spike rejection
  3. isolated interior spike rejection
  4. short multi-sample excursion rejection
  5. supported interpolation of isolated rejected samples
  6. continuous altitude-run identification
  7. reliable-run classification
  8. distance-domain elevation smoothing
  9. cumulative corrected signed change
  10. reliable-interval counting
  11. deadband-confirmed cumulative ascent and descent
  12. profile summary construction
- One output entry corresponds to one input route point.
- Swift retains `ElevationProfile`, `ElevationProfileSample`, route-point UUID
  ownership, public query methods, distance-boundary lookup, interpolation
  APIs, `RangeChange`, policy ownership, cancellation, diagnostics, and
  persistence.
- Route-point UUIDs never cross the boundary.
- Native input and output are caller-owned; C++ retains nothing and performs
  no callback.
- Output is used as the native route-sized workspace after validation.
- No route-sized C++ heap allocation is allowed.
- One call occurs per profile build; no call occurs per sample or run.
- Exact output parity is required against the independent Swift oracle.
- No schema, analysis-version, UI, or importer changes.

## Acceptance evidence

- Native C++ tests cover boundary, policy, each algorithm stage, and large routes.
- At least 1,000 deterministic generated bridge fixtures match the oracle.
- Production `ElevationProfile` parity tests cover samples, snapshots, and
  public distance queries.
- SegmentDetector parity remains green without kernel changes.
- Boundary and public AST validation pass.
- Release benchmarks document ordinary, 100k, and product-limit behavior.

Checked task boxes do not replace tests or benchmark evidence.

## Non-goals

Do not migrate: MovementProfile, WorkoutTimeline construction, route metrics,
importers, public models, formatting, persistence, or UI.
