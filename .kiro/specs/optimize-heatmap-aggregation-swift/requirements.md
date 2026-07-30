# Swift Personal Heatmap Aggregation Optimization Requirements

This phase is a bounded **Swift-only** optimization of Personal Heatmap
cross-workout aggregation. It adds no C++ API, no new language boundary, no
native cross-workout accumulator, and no change to the per-workout coverage
algorithm.

Checked task boxes do not prove completion. Exact snapshot parity, focused
tests, complete-builder benchmarks, phase profiles, boundary validation, and CI
are the evidence.

## Requirements

### Requirement 1: Scope and behavioural compatibility

- **1.1**: `PersonalHeatmapBuilder` public API,
  `PersonalHeatmapConfiguration`, `PersonalHeatmapSnapshot`, diagnostics,
  statistics, date filtering, adaptive retry rules, effective cell sizes,
  minimum-workout filtering, intensity, bounds, and rendered-cell budget MUST
  remain unchanged.
- **1.2**: `PersonalHeatmapCellID` equality, Y-then-X comparison, geographic
  meaning, and keyed `Codable` representation MUST remain unchanged.
- **1.3**: No persisted schema, analysis version, normalization version, UI,
  importer, or C++ source/header may change.
- **1.4**: Complete snapshots MUST remain exactly equal to
  `SwiftPersonalHeatmapBuilderOracle`.

### Requirement 2: One-word cell hashing

- **2.1**: `PersonalHeatmapCellID.hash(into:)` MUST incorporate both signed
  coordinates by reinterpreting them with `UInt64(bitPattern:)`.
- **2.2**: The coordinates MUST be mixed with wrapping integer arithmetic into
  one 64-bit word, and `Hasher.combine` MUST be invoked exactly once.
- **2.3**: The mixed word MUST remain an internal input to Swift `Hasher`; it
  MUST NOT be persisted, exposed, used for equality, or treated as stable
  across processes.
- **2.4**: Hashing MUST allocate nothing, require no Foundation operation, and
  handle negative, zero, and extreme `Int64` pairs.

### Requirement 3: Bounded reservation hints

- **3.1**: Each adaptive pass MUST reserve the global counts dictionary before
  inserting cells.
- **3.2**: The first-pass hint MUST derive from a capped sum of route points in
  date-eligible workouts and an overflow-safe rendered-budget bound.
- **3.3**: A later-pass hint MUST derive from half of the previous pass's
  actual aggregated-cell count, rounded up, and the same rendered-budget bound.
- **3.4**: Every hint MUST be nonnegative and bounded between the useful
  minimum when applicable and a private maximum of 262,144 entries.
- **3.5**: A reservation is an optimization hint only. It MUST NOT truncate
  cells, reject workouts, alter output, persist, become public configuration,
  or become a product/library limit.

### Requirement 4: Direct native-buffer accumulation

- **4.1**: Interop MUST expose pure-Swift
  `RunPlayPersonalHeatmapCoverageMetadata` with cell, projected-point,
  effective-segment, and invalid-interval counts.
- **4.2**: Production MUST call `accumulateCoverage(...into:isCancelled:)`,
  which increments the caller's Swift dictionary while the caller-owned native
  output buffer is alive and returns only compact metadata.
- **4.3**: The production path MUST NOT create a per-workout
  `[PersonalHeatmapCellID]`.
- **4.4**: `coverage(...)` MAY remain for parity and bridge tests.
- **4.5**: Output allocation, capacity negotiation, native invocation, status
  mapping, summary validation, and capacity-hint updates MUST have one shared
  implementation used by coverage, accumulation, and profiling.
- **4.6**: The native buffer closure MUST be nonescaping and private to
  Interop. No unsafe pointer or C++ type may escape, be retained, or appear in a
  non-Interop signature.
- **4.7**: Direct consumption MUST check cancellation every 2,048 cells.

### Requirement 5: Native-call and cancellation contracts

- **5.1**: Production MUST continue to make one coverage operation per workout
  per adaptive pass, plus only the existing exact-capacity retry when required.
- **5.2**: There MUST be no per-cell or per-interval native call, callback into
  Swift, retained native accumulator, or whole-library native operation.
- **5.3**: Cancellation detected after local dictionary mutation MUST throw
  from the pass. The local counts dictionary MUST be discarded and no partial
  snapshot or shared-model mutation may be published.

### Requirement 6: Profiling and benchmarks

- **6.1**: A test-only profiled accumulation operation MUST reuse production
  accumulation and report output allocation, native execution, capacity
  retries, direct cell consumption/counting, and cell count.
- **6.2**: Ordinary production calls MUST read no profiling clock.
- **6.3**: The pipeline profile MUST model the new production flow and label
  direct consumption/counting separately from the historical array-translation
  diagnostic.
- **6.4**: Profile accounting residue MUST remain at most 5%, and profiled
  reconstruction / public builder MUST remain at most 1.15x.
- **6.5**: Performance acceptance MUST use complete production-builder runs,
  repeated release profiles, and a same-binary aggregation microbenchmark.
- **6.6**: The microbenchmark MUST use deterministic high-overlap, low-overlap,
  many-tiny-workout, negative-index, and representative update distributions;
  five warm-ups and twenty measured iterations; median and p90; and an explicit
  environment-variable opt-in rather than an ordinary CI wall-clock assertion.

### Requirement 7: Verification

- **7.1**: Hash tests MUST cover coordinate independence, negative/zero/extreme
  values, Codable round trip, comparison order, at least 100,000 deterministic
  grid IDs, and repeated dictionary updates without asserting `hashValue`.
- **7.2**: Capacity-policy tests MUST cover zero, tiny, normal, capped,
  overflowing, initial, later, odd, and output-invariance cases.
- **7.3**: Bridge tests MUST compare array coverage with direct accumulation
  across empty, single, repeated, loop, segmented, invalid-gap,
  oversized-interval, capacity-retry, cached-capacity, negative-index,
  deterministic, repeated-update, and cancellation fixtures.
- **7.4**: Generated end-to-end parity MUST cover at least 1,000 deterministic
  library/configuration fixtures and compare complete snapshots exactly.
- **7.5**: Boundary validation MUST mechanically require production
  accumulation, forbid production array coverage, keep profiling test-only,
  contain unsafe/native types in Interop, and preserve the existing single
  native coverage API.
