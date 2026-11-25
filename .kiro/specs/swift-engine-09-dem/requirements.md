# DEM tile planning and sampling Swift port

- Produce the same planned tile lists, per-point statuses, counts and elevation bits as
  the C++ kernels, using one shared footprint rule so the sampler never reads a tile the
  planner did not list.
- Preserve the three contracts the correction pass depends on: `tile_budget_exceeded`
  means "keep recorded elevation", the tile directory is validated before the first
  output is produced, and a missing tile is a per-point status, not an error.
- One planning call and one sampling call per correction pass; no call per point or per
  tile. Swift keeps tile discovery, file reading and image decoding, the tile budget,
  elevation precedence, public models, cancellation and persistence.
- Move the DEM limits out of the C++ constants: the engine owns `EngineDemLimits` and
  `RunPlayEngineLimits` projects them.
- Retain the unchanged C++ kernels only as a differential and benchmark oracle until the
  stack removes C++.
