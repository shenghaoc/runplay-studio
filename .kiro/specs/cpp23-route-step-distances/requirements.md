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

- The production bridge must accept every route size currently supported by
  the app. Do not silently reduce supported workout size.
