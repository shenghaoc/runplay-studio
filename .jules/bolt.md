## 2025-02-20 - Performance Optimization for SegmentDetector
**Learning:** `SegmentDetector` used linear `firstIndex(where:)` and `lastIndex(where:)` within a sliding window algorithm that processed GPS routes, causing a serious bottleneck (`O(W * N)`) for long workouts.
**Action:** Replaced linear searches with custom binary search implementations tailored for the strictly increasing `distanceFromStartMeters` field, transforming the time complexity of distance window searches to `O(log N)` and overall algorithm to `O(W log N)`.

## 2025-06-25 - DateFormatter Initialization Overhead in Parsing Loops
**Learning:** Instantiating `ISO8601DateFormatter` (an Objective-C bridged class with locale/calendar setup) on every trackpoint parsed in GPX/TCX files causes significant CPU overhead and object churn in Swift.
**Action:** Cache `DateFormatter` instances as instance properties when they are used inside large loops, especially in file importers parsing thousands of nodes.
