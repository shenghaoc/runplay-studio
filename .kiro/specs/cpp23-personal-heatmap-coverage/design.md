# Personal Heatmap Route Coverage C++23 Migration Design

## Architecture Overview

```text
PersonalHeatmapBuilder (Swift)
    ├── Date filtering & trustworthy date evaluation
    ├── Native route input conversion (once per date-eligible workout)
    ├── Prepared batch (`RunPlayPersonalHeatmapPreparedBatch`)
    ├── Adaptive resolution loop (cellSizeMeters doubling)
    │     └── Per workout: invoke bridge -> C++ coverage kernel
    ├── Global distinct-workout cell aggregation (`[PersonalHeatmapCellID: Int]`)
    └── Snapshot finalization (intensity normalization, bounds, statistics)
            ↓
RunPlayPersonalHeatmapCoverageBridge (Swift Interop)
            ↓
RunPlayEngineCpp (C++23)
    ├── PersonalHeatmapCoverage.hpp / .cpp
    ├── Web Mercator projection & cell quantization
    ├── Same-segment interval validation & supercover grid traversal
    └── Unique cell set & deterministic sorting (y then x)
```

## Data Types

### C++ Header (`PersonalHeatmapCoverage.hpp`)
```cpp
namespace runplay {

inline constexpr double personal_heatmap_max_latitude_degrees = 85.05112878;
inline constexpr std::size_t personal_heatmap_default_maximum_cells_per_interval = 10'000;

struct PersonalHeatmapRouteSample final {
    double latitude{0};
    double longitude{0};
    std::int64_t route_segment_index{0};
};

struct PersonalHeatmapCellIndex final {
    std::int64_t x{0};
    std::int64_t y{0};
};

enum class PersonalHeatmapCoverageStatus : std::uint8_t {
    success,
    invalid_input_buffer,
    invalid_output_buffer,
    insufficient_output_capacity,
    invalid_configuration,
    invalid_input_contract,
    allocation_failure,
    internal_failure,
};

struct PersonalHeatmapCoverageSummary final {
    PersonalHeatmapCoverageStatus status{PersonalHeatmapCoverageStatus::success};
    std::uint64_t input_sample_count{0};
    std::uint64_t valid_projected_point_count{0};
    std::uint64_t effective_segment_count{0};
    std::uint64_t invalid_interval_count{0};
    std::uint64_t required_cell_count{0};
    std::uint64_t written_cell_count{0};
};

[[nodiscard]]
PersonalHeatmapCoverageSummary
compute_personal_heatmap_workout_coverage(
    const PersonalHeatmapRouteSample* samples,
    std::size_t sample_count,
    double cell_size_meters,
    double maximum_interval_meters,
    std::size_t maximum_cells_per_interval,
    PersonalHeatmapCellIndex* output_cells,
    std::size_t output_capacity
) noexcept;

} // namespace runplay
```

## C++ Kernel Logic Details
1. **Coordinate Validation & Projection**:
   - Accepts samples where latitude is in `[-90, 90]` and longitude is in `[-180, 180]`.
   - Clamps latitude to `[-85.05112878, 85.05112878]`.
   - Normalizes longitude into `(-180, 180]`.
   - Projects using spherical Web Mercator (`x = R * lonRad`, `y = R * log(tan(pi/4 + latRad/2))`).
2. **Effective Segments & Gaps**:
   - Invalid coordinates set `requires_new_segment = true`.
   - Source segment index changes or `requires_new_segment` start a new `effective_segment`.
   - Points separated by invalid coordinates or segment changes are never connected by intervals.
3. **Point & Interval Coverage**:
   - Valid projected points immediately contribute their cell to the workout's cell set.
   - Adjacent points in the same effective segment are tested:
     - `length > maximum_interval_meters`: skip traversal, increment `invalid_interval_count`.
     - `length == 0`: stationary point, cell already present.
     - Otherwise: execute 2D Amanatides–Woo supercover grid traversal up to `maximum_cells_per_interval`.
4. **Unique Cell Storage & Output**:
   - Cells are accumulated into a `std::unordered_set<PersonalHeatmapCellIndex>` (or custom hash set/flat set).
   - Once all points/intervals are processed, `required_cell_count` is set to the set size.
   - If `output_capacity < required_cell_count`, return `insufficient_output_capacity` without writing to `output_cells`.
   - If `output_capacity >= required_cell_count`, sort cells (first by `y`, then by `x`), write to `output_cells`, and set `written_cell_count = required_cell_count`.

## Swift Interop Design
- `RunPlayPersonalHeatmapPreparedBatch` holds native memory buffers for all date-eligible workouts.
- Prepared batch converts `[RoutePoint]` to contiguous `[PersonalHeatmapRouteSample]` per workout once during preparation.
- During adaptive retries, `PersonalHeatmapBuilder` invokes `batch.coverage(workoutIndex:cellSizeMeters:...)` which calls `compute_personal_heatmap_workout_coverage` without native re-allocation or re-conversion of input samples.
- Swift uses initial output capacity hint `max(64, sampleCount * 2)` capped at 262,144 cells. If `insufficient_output_capacity` is returned, Swift reallocates the reported `required_cell_count` and re-runs C++ for that workout. The successful capacity is cached as the hint for subsequent adaptive passes.
