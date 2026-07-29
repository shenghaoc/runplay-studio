# Personal Heatmap Route Coverage C++23 Migration Requirements

## Requirements

### Requirement 1: Per-Workout Native Coverage Kernel
- **1.1**: The C++ engine MUST expose a single bulk function `compute_personal_heatmap_workout_coverage` that computes grid coverage for one workout route at a time.
- **1.2**: The C++ kernel MUST handle coordinate validation, Web Mercator projection (clamping latitude to ±85.05112878°, normalizing longitude to (-180, 180]), grid-cell quantization using floor division, same-segment interval validation, Amanatides–Woo supercover grid traversal, cell de-duplication per workout, and deterministic sorting (first by y, then by x).
- **1.3**: The C++ kernel MUST handle invalid coordinates and source segment changes by breaking route continuity, preventing synthetic heat corridors across gaps.

### Requirement 2: Swift Ownership & Aggregation
- **2.1**: Swift `PersonalHeatmapBuilder` MUST retain date filtering, trustworthy date selection, adaptive resolution loop orchestration, global distinct-workout count accumulation, minimum workout count filtering, normalized intensity calculation, cell bounds unprojection, final heatmap bounds, statistics, diagnostics, and public `PersonalHeatmapSnapshot` generation.
- **2.2**: Native route input samples MUST be converted once per date-eligible workout into a cached native buffer (`RunPlayPersonalHeatmapPreparedBatch`) and reused across adaptive resolution retries without rebuilding.

### Requirement 3: Boundary Safety & Memory Semantics
- **3.1**: The C++ function MUST be `noexcept` and return structured status without throwing exceptions across the Swift/C++ language boundary.
- **3.2**: The boundary MUST operate synchronously on caller-owned buffers (immutable input sample array, mutable output cell index buffer). C++ MUST NOT retain pointers or perform callbacks into Swift.
- **3.3**: Output buffer capacity overflow MUST return `insufficient_output_capacity` with the required capacity count, leaving output memory unmodified. Swift MUST allocate the exact required capacity and retry without re-converting native inputs.

### Requirement 4: Cooperative Cancellation
- **4.1**: Swift MUST check cooperative cancellation before conversion, before each adaptive pass, between workouts, after native calls, and during output array translation.
- **4.2**: The native per-workout C++ call duration MUST be bounded (< 500 ms for 1,000,000 route points).

### Requirement 5: Test Parity & Architectural Constraints
- **5.1**: Public Swift heatmap models (`PersonalHeatmapProjection`, `PersonalHeatmapGridTraversal`, `PersonalHeatmapSnapshot`, `PersonalHeatmapCellID`) MUST remain unchanged and public.
- **5.2**: SceneKit/Comparison route projection services remain un-migrated in Swift.
- **5.3**: Native C++ tests, Swift bridge unit/parity tests, fixed-seed generated fixture tests (1,000 fixtures), ASan/UBSan runners, AST validation, boundary script validation, and release benchmarks MUST pass cleanly with zero warnings.
