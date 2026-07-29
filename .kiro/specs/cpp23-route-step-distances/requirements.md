# Requirements: C++23 Route Step Distances

## Introduction

Migrate the complete coordinate-derived route step-distance calculation into
C++23 and use it in production distance normalization through one bulk
Swift/C++ call. This is the first production algorithm cutover.

The C++ kernel computes one full step-distance series. One Swift-owned output
buffer is filled in one call. Only distance normalization cuts over in this
PR; earlier quality stages still use Swift geodesy. `legacyDistancePolicy`
remains Swift unless reuse of the same complete bulk result is free of scope
expansion. Cancellation is checked immediately before and after the native
call and during subsequent Swift accumulation.

Checked task boxes do not replace test and CI evidence.

## Requirements

### R1. Bulk step-distance kernel

- C++ exposes `compute_route_step_distances` taking a borrowed
  `const RouteInputSample*` input buffer, sample count, caller-owned
  `double*` output buffer, and output capacity.
- The function is `[[nodiscard]]` and `noexcept`.
- Output index `i` corresponds to input index `i`.
- First step is `+0.0`.
- Segment-boundary steps are `+0.0` and increment
  `segment_transition_count`.
- Invalid same-segment coordinate pairs yield `+0.0` and increment
  `invalid_coordinate_pair_count`, matching `GeoDistance.distanceMeters`.
- Valid same-segment pairs use `haversine_distance_meters` without
  reimplementing Haversine.
- Total distance is a left-to-right sum of the step series.

### R2. Error and no-write semantics

- Expected failures return a compact status summary without exceptions.
- On any error status the output buffer is completely unchanged.
- Capacity is validated before writing any output entry.
- Empty routes succeed with null pointers allowed.
- Counts above `max_route_input_samples` return `resource_limit`.

### R3. Allocation-free summary

- `RouteStepDistanceSummary` is standard-layout, trivially copyable, and
  nothrow copy-constructible.
- No heap allocation occurs in the kernel.

### R4. Shared Swift route-input builder

- Route-to-`RouteInputSample` conversion lives in one shared component under
  `RunPlayCore/Sources/Interop/`.
- `RunPlayRouteBridge` reuses that builder; digests remain parity-stable.

### R5. Swift step-distance bridge

- `RunPlayRouteStepDistanceBridge` performs exactly one native call.
- Swift owns both input construction and the mutable output buffer.
- Pointer/capacity failures surface as engine contract violations; resource
  limits surface as resource-limit errors.
- No silent fallback to scalar C++ or a second Swift step implementation.

### R6. Production cutover scope

- Only `RouteQualityProcessor.normalizeDistances` consumes the C++ step series
  for coordinate-derived segments.
- Fully supplied-distance routes skip the native call.
- Earlier stages continue to use Swift `GeoDistance`.
- Swift retains policies, provenance, cancellation, diagnostics, and models.

### R7. Isolation and validation

- Only the step-distance bridge may invoke `compute_route_step_distances`.
- Platform and Studio must not import the engine.
- Public AST validation allows the documented pointer APIs only.

### R8. Route size

- The production bridge must accept every route size the app supports. Before
  this PR the GPX, TCX, and JSON importers had no route-point or payload cap,
  so "supported size" was unbounded and the engine ceiling could have rejected
  an accepted workout.
- The app's supported size is therefore bounded explicitly rather than left
  implicit: `WorkoutImportResourceLimits.maxRoutePointCount` is 1,000,000 route
  points per resulting workout and `maxSourceFileBytes` is the existing 100 MB
  FIT container value, reused so no format restates it.
- The limit is applied per resulting workout — total GPX `<trkpt>`, trackpoints
  in the selected TCX activity, decoded JSON `routePoints`, and route points in
  each resulting FIT session, which is checked explicitly rather than inferred
  from the decoded-message ceiling. Archive entries inherit their format
  importer's limit.
- The payload limit is applied through a bounded reader that consumes at most
  `limit + 1` bytes instead of an unbounded `Data(contentsOf:)`.
- GPX and TCX stop parsing at the first point past the limit.
- `max_route_input_samples` is raised to 1,250,000 — an internal safety ceiling
  25% above the product limit, not a second product limit. R5's single native
  call is preserved: no chunking or streaming redesign is required, because an
  accepted route can never reach the ceiling.
- Exceeding a limit rejects the whole workout with a user-visible error naming
  the limit. Nothing is truncated or partially imported. Batch import fails
  only that candidate. Existing persisted oversized workouts are neither
  deleted nor rewritten.
- `RouteQualityProcessor.process` preflights the same limit so programmatic
  callers fail before the native input buffer is built.
