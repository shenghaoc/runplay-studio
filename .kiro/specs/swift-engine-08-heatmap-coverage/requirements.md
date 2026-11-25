# Personal heatmap coverage Swift port

- Produce the same de-duplicated cell set, sorted by `(y, x)`, and the same valid-point,
  effective-segment and invalid-interval counts as the C++ kernel for every input.
- One synchronous engine call per workout per adaptive attempt. Delete the capacity
  negotiation and its retry call: the engine returns exactly the cells it found.
- Aggregation still increments the cross-workout dictionary directly from the engine's
  cells. Date filtering, the adaptive resolution loop, the minimum-workout-count filter
  and snapshot finalization stay in Swift.
- Move the coverage profiling types out of Core sources into test support, and remove
  their capacity-retry and output-allocation fields.
- Retain the unchanged C++ kernel only as a differential and benchmark oracle until the
  stack removes C++.
