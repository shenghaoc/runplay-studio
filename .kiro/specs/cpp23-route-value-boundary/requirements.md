# Requirements: C++23 Route Value Boundary

## Introduction

Establish the portable C++23 route input value and a single bulk Swift↔C++
inspection boundary so future engine algorithms can receive complete routes
without per-point cross-language calls. This phase is contract and parity
infrastructure only: no production route algorithm, importer, persistence, or
UI behaviour moves to C++.

## Requirements

### R1. Route input value

- C++ exposes a concrete `RouteInputSample` that carries every `RoutePoint`
  field needed for future algorithms, except Swift-owned identity (`UUID`).
- `source_index` is the original Swift array offset used for round-trip mapping.
- Timestamps are exact `Date.timeIntervalSinceReferenceDate` values with no
  rounding or epoch conversion.
- Optional metrics use `std::optional<double>` (or a nameable alias) so absence
  remains distinct from zero and non-finite values.
- `route_segment_index` converts exactly to `std::int64_t` and does not
  truncate.

### R2. Single bulk inspection boundary

- One synchronous `noexcept` call accepts `const RouteInputSample*` plus a
  count for the complete route.
- Swift owns the contiguous input buffer; C++ borrows it only for the call and
  retains nothing.
- A null pointer is valid only when the count is zero.
- Counts above a documented engine batch cap return a resource-limit status
  without traversing the buffer.
- Public headers must not expose `std::vector` or other owning containers for
  this boundary.

### R3. Compact pure-value result

- Inspection returns a compact value (sample counts, optional-field presence
  counts, segment-transition count, first/last `source_index`, field digest).
- The Core adapter converts the result to pure Swift before imported C++ values
  are destroyed.
- C++ types do not appear in public `RunPlayCore` APIs.

### R4. Field-fidelity parity

- Every field on the projected sample participates in a deterministic digest.
- Swift and C++ each implement the digest independently for parity tests.
- Empty routes, absent optionals, multi-segment transitions, signed zeros,
  infinities, NaNs, and large batches (at least 100,000 samples) are covered.

### R5. Architecture and import boundaries

- Only `RunPlayCore/Sources/Interop/` may import `RunPlayEngineCpp`.
- Platform and Studio must not import the engine or traverse C++ containers.
- Boundary validation scripts and CI enforce package graph, public AST pointer
  rules, and Swift import rules.

### R6. Out of scope for this PR

- No production call site uses the route bridge.
- No geodesic, normalisation, elevation, analysis, DTW, heatmap, importer, or
  export algorithm migrates to C++.
- No persisted schema or version changes.
- No user-visible behaviour changes and no performance claims.
- GUI manual testing is not applicable.
