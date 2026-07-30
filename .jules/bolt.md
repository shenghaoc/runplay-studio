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

## 2025-07-28 - O(N) Array Allocations in Min/Max Operations
**Learning:** Extracting maximum or minimum values from arrays using chained higher-order functions like `.compactMap { ... }.filter { ... }.min()` causes intermediate `O(N)` array allocations. When executed frequently on large arrays (like iterating over route points), it creates significant ARC/GC overhead in Swift.
**Action:** Replace chained array transformations with single inline `for` loops that use accumulator variables for state tracking (e.g., `minAlt`), keeping best-case performance at `O(1)` or `O(N)` without intermediate array allocations.

## 2025-07-29 - O(N) Array Allocations in Map Rendering Min/Max Operations
**Learning:** Checking for minimum and maximum values via `.map { ... }.min()` and `.map { ... }.max()` inside map rendering services (like `RouteColoringService`) created unnecessary intermediate O(N) array allocations causing GC pauses during frame rendering.
**Action:** Replaced chained array transformations with single inline `for` loops that simultaneously map values and track local min/max using accumulator variables to optimize memory use during map rendering.

## 2026-07-15 - Redundant O(N) Array Creations for Parameter Passing
**Learning:** Functions like `smoothValues` were being passed mapped arrays like `points.dropLast().map(\.routeSegmentIndex)` as arguments. This creates a full `O(N)` array of integers simply to supply data that already exists sequentially within the original `RouteScenePoint` array, causing unnecessary ARC overhead.
**Action:** Pass the original array (`points`) directly into helper methods instead of creating mapped projection arrays beforehand, and perform inline property access (`points[i].routeSegmentIndex`) inside the helper loop.

## 2026-07-19 - DateFormatter Initialization Overhead in Parsing Loops
**Learning:** Instantiating `ISO8601DateFormatter` as instance properties for parsers created inside the importer class means they are still instantiating every time an importer or parser is created. Given parsers read entire XML structures containing thousands of nodes, and importers may be created dynamically, caching them as instance properties rather than `static let` leads to unnecessary overhead and object churn.
**Action:** Always cache `ISO8601DateFormatter` instances as `static let` properties so they are initialized once per app lifecycle, ensuring no repeated configuration overhead occurs across multiple file parsing events.

## 2026-07-20 - DateFormatter Allocation in CSV Parser Loops
**Learning:** `WorkoutArchiveCSVParser.parseDate` was instantiating `ISO8601DateFormatter` and multiple `DateFormatter` fallback objects on every single CSV cell representing a date. Since CSV files can contain tens of thousands of rows, this created extreme object churn and ARC overhead.
**Action:** Replace inline `DateFormatter` instantiations inside CSV cell parsers with cached `private static let` configurations to guarantee single-time initialization and ensure parsing remains fast across large datasets.

## 2026-07-20 - Concurrency Safety for DateFormatters in Swift 6
**Learning:** `DateFormatter` and `ISO8601DateFormatter` do not conform to the `Sendable` protocol in Swift. When caching them as `static let` properties to optimize parsing loops (like in `WorkoutArchiveCSVParser`), Swift 6 strict concurrency checks will emit a `[#MutableGlobalVariable]` error because non-Sendable static properties are assumed to have shared mutable state and are not concurrency-safe.
**Action:** Since Apple's `DateFormatter` is thread-safe for reading/parsing (once initialized), use the `nonisolated(unsafe)` modifier on the `static let` declarations to suppress the compiler warning and safely share the instances across concurrency domains in Swift 6 codebases.

## 2026-07-20 - Concurrency Safety for DateFormatters Arrays in Swift 6
**Learning:** `DateFormatter` does not conform to `Sendable`. However, when you create an array of them (`[DateFormatter]`), Swift 6 (in some toolchains) infers the array container itself as `Sendable` in certain static let contexts, resulting in an error if you apply `nonisolated(unsafe)` to the array (`'nonisolated(unsafe)' is unnecessary for a constant with 'Sendable' type '[DateFormatter]'`).
**Action:** When caching `DateFormatter` in an array as a static constant, do not apply `nonisolated(unsafe)` to the array if the compiler emits an unnecessary modifier error. Apply it only to the individual non-array formatters.

## 2026-07-22 - Prefer formatted() Over Cached DateFormatter in SwiftUI Views
**Learning:** Caching a `DateFormatter` as a `static let` to avoid O(N) instantiation overhead in SwiftUI render logic works but introduces Swift 6 concurrency complications (`nonisolated(unsafe)` vs `Sendable` inference varies by SDK). For simple date-only or time-only formatting, the modern `formatted(date:time:)` API is inherently `Sendable`, requires no cached instance, and eliminates concurrency concerns entirely.
**Action:** In SwiftUI views targeting macOS 12+, prefer `date.formatted(date: .abbreviated, time: .omitted)` over cached `DateFormatter` instances. Reserve `DateFormatter` caching for complex custom format strings where `formatted()` cannot express the desired output.

## 2026-07-25 - Avoid Closure Overhead in High-Frequency Loops
**Learning:** `MetricSmoother.movingAverage` extracted a slice (`let slice = values[start..<end]`) and then called `.reduce(0, +)` on it inside a high-frequency loop. Similarly, `MovementProfile.init` used `activeDeltas[i...runEnd].reduce(0, +)` and `distanceDeltas[i...runEnd].reduce(0, +)` inside its hysteresis merge loop. While `ArraySlice` is a view and does not allocate O(N) memory, using `reduce` involves closure call overhead for every element summed. Since this runs on every iteration across thousands of points, it creates unnecessary ARC overhead and slows down execution.
**Action:** Replace `.reduce` and similar higher-order functions on `ArraySlice` inside windowing or merge loops with a simple inline `for` loop that iterates over the array by index, accumulating the result manually to avoid closure and ARC overhead. For further optimization, consider a sliding window running sum to reduce time complexity to O(N).

## 2026-07-27 - Avoid Multiple .map Array Allocations in Initializers
**Learning:** Initializing objects with multiple properties derived from the same large array using `.map { ... }` (e.g. `distances: points.map(\.distance), segments: points.map(\.segment)`) creates several redundant intermediate O(N) array allocations and requires iterating the collection multiple times, causing unnecessary ARC overhead.
**Action:** When extracting multiple property arrays from a source collection, use a single inline `for` loop to build all target arrays simultaneously, avoiding multiple full passes and temporary mappings.

## 2026-07-28 - Array Allocation in CSV Export Logic
**Learning:** `CSVRow.joined` used `fields.map { escape($0) }.joined(separator: ",")` which creates an intermediate `O(N)` array of strings for every single row in the CSV export. Because exports can be thousands of rows, this resulted in massive object churn and ARC overhead.
**Action:** Replace `map.joined()` chains inside large string building processes with an inline `for` loop that iterates over elements and directly appends to the target string.

## 2026-07-30 - formatted() Is Not a Faster Substitute for a Cached DateFormatter
**Learning:** `Date.formatted(date:time:)` was proposed as a drop-in replacement for the cached `static let DateFormatter` in `RunWorkout.displayName` and `ExportSummaryCardModel.dateText`, on the premise that it is faster and that the cached formatter breaks Swift 6 strict concurrency. Both premises were wrong. Measured over 20,000 formats (release build, Swift 6.3, arm64 macOS): cached `DateFormatter` 0.63 µs/call, `Date.formatted(date:time:)` 0.92 µs/call — the modern API is ~47% *slower* — and a freshly constructed `DateFormatter` per call costs 68.33 µs/call, ~108× the cached baseline. `DateFormatter` is also already `Sendable` on both Darwin and Linux under Swift 6.3, so a `static let DateFormatter` in a `Sendable` struct compiles clean with `-warnings-as-errors` and needs no `nonisolated(unsafe)` (unlike `ISO8601DateFormatter`, which still does). Separately, `Date.FormatStyle` has no `.medium` date style, so `.abbreviated` is not equivalent to `DateFormatter.Style.medium`: it renders differently in `de_DE` (`25.07.2026` vs `25. Juli 2026`), `ja_JP`, and `zh_Hans_CN`.
**Action:** Keep cached `static let DateFormatter` instances for date rendering on model paths. Read the 2026-07-22 entry above as scoped to what it actually established: `formatted()` is a reasonable convenience in SwiftUI view bodies where the formatting cost is dwarfed by layout, not a performance win anywhere. Before replacing a cached formatter, measure it, and confirm style equivalence in a non-English locale — never assume `.abbreviated` equals `.medium`. Guard the styles with a test that compares against a reference `DateFormatter` rather than a hard-coded string, so the assertion stays deterministic on any CI locale.
