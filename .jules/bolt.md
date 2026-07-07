## 2025-02-20 - Performance Optimization for SegmentDetector
**Learning:** `SegmentDetector` used linear `firstIndex(where:)` and `lastIndex(where:)` within a sliding window algorithm that processed GPS routes, causing a serious bottleneck (`O(W * N)`) for long workouts.
**Action:** Replaced linear searches with custom binary search implementations tailored for the strictly increasing `distanceFromStartMeters` field, transforming the time complexity of distance window searches to `O(log N)` and overall algorithm to `O(W log N)`.
