# Swift Personal Heatmap Aggregation Optimization Design

## Decision and scope

The previous profile selected a Swift optimization because per-workout native
coverage remains dominant and a native cross-workout accumulator would violate
the current ownership, cancellation, and resource-bound contracts. This phase
implements the three measured Swift changes only:

1. reserve the global dictionary with a bounded adaptive hint;
2. mix `PersonalHeatmapCellID` into one `Hasher` input;
3. count directly from caller-owned native output storage.

No C++ declaration, implementation, or algorithm changes.

## Production flow

Before:

```text
C++ output buffer
    -> allocate [PersonalHeatmapCellID]
    -> translate every cell
    -> return array
    -> hash every cell into the global dictionary
```

After:

```text
C++ output buffer
    -> nonescaping Interop closure while buffer is alive
        -> translate one X/Y pair
        -> construct PersonalHeatmapCellID
        -> hash and increment the global Swift dictionary
    -> return pure-Swift coverage metadata
```

The array-returning operation remains available to tests and independent
historical diagnostics, but `PersonalHeatmapBuilder` never calls it.

## Cell hash

`PersonalHeatmapCellID.hash(into:)` reinterprets both signed coordinates as
`UInt64`, multiplies them by independent odd constants with wrapping
arithmetic, XOR-combines them, and applies avalanche steps before one
`Hasher.combine` call:

```swift
var mixed = xBits &* 0x9E37_79B1_85EB_CA87
mixed ^= yBits &* 0xC2B2_AE3D_27D4_EB4F
mixed ^= mixed >> 29
mixed &*= 0x1656_67B1_9E37_79F9
mixed ^= mixed >> 32
hasher.combine(mixed)
```

The word is not a stable external hash. Equality and Codable continue to use
the original `x` and `y` fields.

## Capacity policy

Private constants:

```text
minimum useful hint       = 64
maximum reservation hint = 262,144
rendered budget scale     = 64
```

The rendered-budget bound uses overflow-safe clamping:

```text
min(maximumReservationHint, maximumRenderedCellCount * 64)
```

The date-eligible route-point total is accumulated only until the private
maximum. The first hint is:

```text
min(maximumReservationHint,
    max(minimumHint,
        min(cappedTotalRoutePointCount, renderedBudgetBound)))
```

The later hint is:

```text
min(maximumReservationHint,
    max(minimumHint,
        min((previousAggregatedCellCount + 1) / 2,
            renderedBudgetBound)))
```

The implementation avoids overflowing addition when rounding up. Empty or
otherwise small inputs may reserve the minimum; any estimate may be wrong
without changing correctness because dictionary growth remains ordinary.

## Interop lifetime

One private generic helper owns the complete native operation:

```swift
private func withNativeCoverageOutput<Result>(
    ...,
    _ body: (
        UnsafeBufferPointer<runplay.PersonalHeatmapCellIndex>,
        RunPlayPersonalHeatmapCoverageMetadata
    ) throws -> Result
) throws -> Result
```

The closure is nonescaping by default. The helper:

1. validates index/configuration and cancellation;
2. loads the per-workout capacity hint;
3. allocates the caller-owned output buffer;
4. calls the existing C++ coverage function;
5. performs the existing exact-capacity retry;
6. maps status and validates written/required counts;
7. updates the cached capacity hint;
8. creates a read-only buffer view valid only for the closure invocation.

No pointer, buffer view, native value, or callback is retained. C++ continues
to borrow Swift-owned buffers synchronously.

`coverage(...)` uses the helper to materialize the compatibility array.
`accumulateCoverage(...)` uses it to update the global dictionary directly and
return metadata. Profiling wraps the same production accumulation body with
optional `ContinuousClock` reads.

## Builder integration

Date filtering still happens once, followed by one cached native input batch.
The builder computes the first capacity hint from date-eligible workouts, then:

```text
for each adaptive pass
    reserve counts using current hint
    for each eligible workout
        accumulateCoverage(..., into: &counts)
        if metadata.cellCount > 0
            update included-workout, safe-distance, and invalid-interval totals
    filter counts
    if budget satisfied: finalize unchanged
    otherwise:
        next hint = policy(previousAggregatedCellCount: counts.count)
        double cell size
```

Cancellation can occur while the local pass dictionary has partial increments.
The throw abandons that local value before finalization, so no snapshot is
published and no workout or shared model is mutated.

## Profiling

The production-equivalent reconstruction switches from:

```text
profiledCoverage -> array translation -> separately timed dictionary loop
```

to:

```text
profiledAccumulateCoverage -> direct consumption/counting
```

Nested bridge phases are native execution, output allocation/retries, and
direct cell consumption/counting. The historical array-returning call may be
measured separately and must be labelled non-production.

The skipped same-binary microbenchmark compares synthesized two-field hashing,
no reservation, and materialized per-workout arrays against the production
hash, production reservation policy, and direct accumulation. It reports
median and p90 without placing wall-clock thresholds in ordinary CI.

## Boundary enforcement

`scripts/validate-cpp-boundaries.sh` additionally verifies:

- `PersonalHeatmapBuilder` names `accumulateCoverage` and does not invoke
  `.coverage`;
- the profiling accumulation API remains internal and test-only;
- unsafe native cell-buffer types remain in Interop;
- the sole native coverage symbol remains in the existing bridge;
- no C++ file or public C++ API is added or changed;
- Platform and Studio still cannot import `RunPlayEngineCpp`.

## Non-goals

- native cross-workout aggregation or retained native state;
- new whole-library limits;
- per-cell native calls;
- changes to projection, traversal, coverage ordering, public models,
  persistence, UI, importers, or rendered budgets;
- stable external hashes or third-party hashing libraries.
