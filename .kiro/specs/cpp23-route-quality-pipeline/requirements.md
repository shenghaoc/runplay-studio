# Requirements: C++23 Route Quality Geometry Pipeline

## Introduction

Migrate route-quality stages 2–4 into one combined C++23 production kernel and
one bulk language-boundary crossing. Swift stage 1 remains authoritative for
validation, sanitization, ordering, elapsed normalization, and initial
source-segment compaction. C++ performs outlier evidence and removal, implicit
gap inference, final segment compaction, supplied-distance validity, distance
policy selection, and cumulative normalized distance. Swift resumes with
source-speed validation, elevation, diagnostics translation, and public result
construction.

Performance is evaluated using complete Swift stages 2–4 versus the complete
C++ bridge, including conversion. Checked task boxes do not replace tests or CI.

## Requirements

### R1. Combined geometry kernel

- C++ exposes `process_route_quality_geometry` taking:
  - borrowed `const RouteInputSample*` input;
  - sample count;
  - value `RouteQualityGeometryPolicy`;
  - value `RouteQualityDistancePolicy`;
  - optional borrowed `const std::uint8_t*` selection buffer and count;
  - caller-owned `RouteQualityOutputSample*` output and capacity.
- The function is `[[nodiscard]]` and `noexcept`.
- Output index `i` corresponds to input index `i`.
- Exactly one bulk call performs stages 2–4 in order.
- The kernel reuses internal geodesy and pairwise step helpers; it must not
  call the public `compute_route_step_distances` boundary.

### R2. Ownership and no-write semantics

- Swift owns every buffer. C++ retains no pointer and performs no callback.
- On success, C++ writes exactly `sample_count` output entries.
- On any error status, C++ writes nothing to the output buffer.
- Empty routes succeed with null pointers allowed.

### R3. Exact stage semantics

- Isolated coordinate-outlier candidates only; adjacent candidates retained.
- Gap inference uses the retained logical sequence.
- Inferred boundaries start new final segments.
- Supplied validity resets per final segment.
- Selected source segments propagate through inferred child segments.
- No distance is added across explicit or inferred boundaries.
- Point identity and order are preserved.

### R4. Swift stage split

- Stage 1 remains in Swift and feeds ordered samples into the bridge.
- Production `RouteQualityProcessor` invokes only the pure-Swift
  `RunPlayRouteQualityBridge`.
- Production no longer calls `RunPlayRouteStepDistanceBridge`.
- Source-speed validation and elevation remain Swift.
- Product limit (1,000,000 points) and engine ceiling (1,250,000) are unchanged.

### R5. Transitional step-distance boundary

- Public step-distance API remains for focused tests and historical benchmarks.
- Combined production path uses internal shared step logic only.

### R6. Cancellation

- Cancellation remains Swift-owned with checks during conversion, immediately
  before and after the native call, and during output translation.
- No C++ callbacks, global flags, or per-stride native calls.

### R7. Validation and isolation

- Only Interop files import `RunPlayEngineCpp`.
- Only `RunPlayRouteQualityBridge` invokes `process_route_quality_geometry`.
- Public AST validation allows the documented pointer APIs only.
- Platform and Studio neither import nor depend directly on the engine.
