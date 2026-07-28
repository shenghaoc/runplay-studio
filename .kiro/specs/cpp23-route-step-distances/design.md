# Design: C++23 Route Step Distances

## Architecture

```text
RunPlayStudio
    ↓
RunPlayPlatform
    ↓
RunPlayCore
    ├── RouteQualityProcessor.normalizeDistances
    │       ↓ one bulk call (when any segment is coordinate-derived)
    ├── RunPlayRouteStepDistanceBridge
    └── RunPlayRouteInputBuffer (shared native sample builder)
            ↓
      RunPlayEngineCpp
      ├── RouteInputSample
      ├── haversine_distance_meters
      └── compute_route_step_distances
```

## Data flow

```text
Swift [RoutePoint]
    → one ContiguousArray<RouteInputSample>
    → one ContiguousArray<Double> output
    → one compute_route_step_distances call
    → Swift cumulative normalization / policy / provenance
```

Swift owns both buffers. C++ borrows them only for the synchronous call and
retains neither. C++ writes exactly `sample_count` output entries on success
and writes nothing on error.

## C++ boundary

```cpp
RouteStepDistanceSummary compute_route_step_distances(
    const RouteInputSample* samples,
    std::size_t sample_count,
    double* step_distances_meters,
    std::size_t step_distance_capacity
) noexcept;
```

Approved public pointer surfaces remain:

1. `inspect_route_batch(const RouteInputSample*, std::size_t)`
2. `compute_route_step_distances(const RouteInputSample*, std::size_t, double*, std::size_t)`

## Production integration

After `useSupplied` is determined:

- if every segment uses supplied distances → skip native call;
- otherwise → cancellation probe, one native call, cancellation probe, then
  Swift accumulation using `nativeStepDistances[index]` for coordinate-derived
  steps.

`legacyDistancePolicy` stays on Swift `GeoDistance` in this PR; reusing the
bulk series there would expand the production surface beyond distance
normalization without a clear amortization benefit.

## Cancellation

```text
before native step-distance call
after native step-distance call
during subsequent Swift accumulation
```

The kernel performs one linear pass with no allocation and no Swift callback.

## Non-goals

Earlier route-quality stages, elevation, timeline, splits, DTW, heatmaps,
importers, schema, analysis version, and UI remain out of scope.
