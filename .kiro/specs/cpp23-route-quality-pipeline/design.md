# Design: C++23 Route Quality Geometry Pipeline

## Architecture

```text
RouteQualityProcessor
  ├── basicFieldValidation (Swift stage 1)
  ├── RunPlayRouteQualityBridge.process (one bulk call)
  │     ├── RunPlayRouteInputBuffer (one conversion)
  │     ├── optional selection byte buffer
  │     ├── caller-owned RouteQualityOutputSample buffer
  │     └── process_route_quality_geometry (C++)
  ├── validateSourceSpeeds (Swift)
  └── ElevationProfile (Swift)
```

## Boundary

```text
ordered Swift RoutePoint array
  → one RouteInputSample buffer
  + optional selected-segment byte buffer
  + one caller-owned output buffer
  → one process_route_quality_geometry call
  → retained Swift RoutePoint array
```

Swift owns every buffer. C++ retains nothing and performs no callback.

## Public C++ surface

- `RouteQualityGeometryPolicy` — stages 2–4 thresholds only
- `RouteQualityDistancePolicy` — four policy kinds
- `RouteQualityOutputSample` — one entry per input sample
- `RouteQualityPipelineSummary` — status and aggregate counts
- `process_route_quality_geometry` — single bulk kernel

## Internal sharing

`RouteGeometryInternal.hpp` exposes pairwise step helpers used by both
`compute_route_step_distances` and the combined quality kernel. Haversine is
not duplicated. The public step-distance function is not called from the
combined path.

## Allocation policy

No route-length heap allocation in the kernel. The one-to-one output buffer is
working state for candidate, retention, boundary, segment, distance, and source
fields. Small fixed locals are allowed.

## Complexity

Every stage is linear in the sample count. Segment compaction assigns
normalized indexes in ascending order while walking forward, so the retained
points of one normalized segment always form a contiguous run; distance
normalization therefore walks each segment's own extent instead of rescanning
the whole route per segment. This matters because the native call is
uninterruptible — Swift cannot cancel inside it — so a per-segment full rescan
would turn a route with many pauses into a multi-minute unresponsive call at
the product limit.

Adjacent-candidate conservatism decides retention from the unmodified candidate
flags and only clears ambiguous flags in a second pass. Clearing while deciding
would hide a flag from the next index's lookback and wrongly reject the
trailing member of every adjacent run.

## Error model

Validate buffers, capacity, resource limit, input contract, policy, and
selection before the first output write. Errors return zeroed summary counts
and leave the output buffer byte-for-byte unchanged.

## Performance evaluation

Compare complete Swift stages 2–4 (oracle) to the complete combined bridge
including conversion and projection. Native-kernel-only timing is diagnostic.
Merge gate: combined bridge median ≤ approximately 1.25× Swift stages 2–4.

## Non-goals

Elevation, source-speed migration, projection, heatmap, importers, schema or
analysis-version changes, third-party dependencies, C ABI, Objective-C++, or
callbacks into Swift.
