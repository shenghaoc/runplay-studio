## 2025-02-20 - Performance Optimization for SegmentDetector
**Learning:** `SegmentDetector` used linear `firstIndex(where:)` and `lastIndex(where:)` within a sliding window algorithm that processed GPS routes, causing a serious bottleneck (`O(W * N)`) for long workouts.
**Action:** Replaced linear searches with custom binary search implementations tailored for the strictly increasing `distanceFromStartMeters` field, transforming the time complexity of distance window searches to `O(log N)` and overall algorithm to `O(W log N)`.

## 2025-02-20 - Array Allocation Optimization in Core Services
**Learning:** `RoutePointInterpolator` used array transformations like `.compactMap { ... }.reduce(0, +)` and `.filter { ... }` extensively inside high-frequency window evaluation loops, causing severe `O(N)` overhead due to intermediate array allocations.
**Action:** Replaced functional array operations with pre-filtered inline `for` loops combined with `O(log N)` binary search range narrowing, eliminating memory allocations and drastically reducing CPU overhead during segment detection.

## 2025-02-21 - Performance Optimization for XML Parsers
**Learning:** `ISO8601DateFormatter` (and `DateFormatter`) instantiation is extremely expensive in Swift. Creating a new instance inside a tight loop for every trackpoint in GPX and TCX importers caused severe performance degradation (`O(N)` overhead where `N` is trackpoints).
**Action:** Replaced loop-level formatter instantiation with cached, static `ISO8601DateFormatter` instances that are reused across all parsing iterations, drastically reducing overhead.
