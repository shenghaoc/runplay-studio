## 2025-02-20 - Performance Optimization for SegmentDetector
**Learning:** `SegmentDetector` used linear `firstIndex(where:)` and `lastIndex(where:)` within a sliding window algorithm that processed GPS routes, causing a serious bottleneck (`O(W * N)`) for long workouts.
**Action:** Replaced linear searches with custom binary search implementations tailored for the strictly increasing `distanceFromStartMeters` field, transforming the time complexity of distance window searches to `O(log N)` and overall algorithm to `O(W log N)`.

## 2025-02-20 - Array Allocation Optimization in Core Services
**Learning:** `RoutePointInterpolator` used array transformations like `.compactMap { ... }.reduce(0, +)` and `.filter { ... }` extensively inside high-frequency window evaluation loops, causing severe `O(N)` overhead due to intermediate array allocations.
**Action:** Replaced functional array operations with pre-filtered inline `for` loops combined with `O(log N)` binary search range narrowing, eliminating memory allocations and drastically reducing CPU overhead during segment detection.

## 2025-06-25 - DateFormatter Initialization Overhead in Parsing Loops
**Learning:** Instantiating `ISO8601DateFormatter` (an Objective-C bridged class with locale/calendar setup) on every trackpoint parsed in GPX/TCX files causes significant CPU overhead and object churn in Swift.
**Action:** Cache `DateFormatter` instances as instance properties when they are used inside large loops, especially in file importers parsing thousands of nodes.

## 2025-07-11 - DateFormatter Allocation in Computed Properties and Render Logic
**Learning:** `DateFormatter` was being instantiated inside computed properties (like `RunWorkout.displayName`) and synchronous initialization/rendering functions (like `ExportSummaryCardModel.init` and `ExportFilenameBuilder.formatDateForFilename`). Since these are accessed frequently in UI lists or repeatedly during exports, the repeated allocations caused unnecessary performance bottlenecks.
**Action:** Always replace inline `DateFormatter` instantiations in frequently accessed synchronous logic with `private static let` cached instances to guarantee single-time configuration.

## 2025-07-28 - Array Allocation in MetricSmoother
**Learning:** `MetricSmoother.smoothHeartRate` used `.compactMap { ... }.reduce(0, +)` inside its windowing loop. Because this executes for every point parsed, it resulted in massive intermediate array allocations, causing heavy GC overhead.
**Action:** Replace `compactMap`/`reduce` inside O(N) loops with inline `for` loops to accumulate state variables without generating throwaway arrays.
## 2025-07-28 - O(N) Array Allocations in Iterative Checking and Aggregation Logic
**Learning:** Checking for data presence or aggregating values (like heart rate or pace) over arrays using chained higher-order functions like `.compactMap { ... }.filter { ... }.count` and `.compactMap { ... }.filter { ... }.reduce()` causes intermediate `O(N)` array allocations. When these properties are accessed frequently or within large loops across thousands of points, it creates significant GC and ARC overhead.
**Action:** Replace chained array transformations with single inline `for` loops that use accumulator variables or short-circuit returns (`return true` after finding required elements). This keeps best-case performance at `O(1)` or `O(N)` without `O(N)` intermediate arrays.
