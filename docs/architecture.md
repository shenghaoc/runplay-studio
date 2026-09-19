# RunPlay Studio — Architecture

## Data Flow

```
Import File → Importer → RouteQualityProcessor → Normalized Route + Diagnostics
                                                ↓
                              WorkoutAnalysisContext
                              ├── WorkoutTimeline
                              └── ElevationProfile
                                        ↓
              Analyzer → Summary / Splits / Highlights → Workout Library
                 ├── Replay / Comparison / Exports
                 ├── Personal Heatmap (derived library-level aggregation)
                 └── Charts / Route Projection / Route Colouring
```

### Detailed Flow

1. **Import**: User selects file (JSON, GPX, TCX, FIT)
2. **Parse**: Format-specific importer parses raw data
3. **Normalize**: `RouteQualityProcessor` validates fields, removes only strong isolated coordinate outliers, infers supported recording gaps, normalizes distance, and records distance provenance and quality diagnostics
4. **Correct elevation**: `ElevationProfile` preserves source altitude on each `RoutePoint` while deriving an aligned, gap-safe corrected profile and threshold-confirmed ascent/descent
5. **Build context**: `WorkoutAnalysisContext` owns one immutable profile and a `WorkoutTimeline` built from that same profile
6. **Analyze**: `WorkoutAnalyzer` passes the context to summary, global-distance splits, source-recorded laps (`RecordedLapAnalyzer`), and notable-segment detection so every elevation consumer shares one correction
7. **Persist**: `FileWorkoutLibraryStore` atomically stores the normalized route, provenance, diagnostics, warnings, and versioned analysis snapshot
8. **Control**: `ReplayController` drives an elapsed-clock `PlaybackEngine` whose selected elevation comes from the corrected profile
9. **Render and export**: Charts, route projection/colouring, comparison, and exports consume corrected analysis while raw imported altitude remains source data. Video export uses an independent `WorkoutVideoReplaySampler` (private `PlaybackEngine`) so live replay state is never mutated; Platform owns MapKit map preparation, Core Graphics frames, and AVFoundation encoding; Studio owns the sheet and save panel.

## Module Structure

Dependency direction:

```text
RunPlayStudio → RunPlayPlatform → RunPlayCore → RunPlayEngineCpp
```

```
RunPlayEngineCpp/              # Portable C++23 computational engine
├── include/RunPlayEngineCpp/  # Engine identity plus bulk route/analysis boundaries
├── Sources/                   # C++ implementation
└── Tests/                     # Native C++ test executable sources

RunPlayCore/                   # Platform-neutral Swift facade (no UI frameworks)
├── Sources/
│   ├── Models/                # Data structures (RunWorkout, RoutePoint, etc.)
│   ├── Accessibility/         # Pure spoken summaries and chart accessibility models
│   ├── Importers/             # File format parsers (JSON, GPX, TCX, FIT)
│   ├── Interop/               # Internal Swift adapter over RunPlayEngineCpp
│   └── Services/              # Analysis, splits, segments, comparison, projection, export
└── Tests/
    └── RunPlayCoreTests/      # Platform-neutral tests (includes engine bridge tests)

RunPlayPlatform/               # macOS non-UI layer (MapKit, SceneKit, AppKit values)
├── Sources/                   # Route/map data and rendering services
└── Tests/                     # Platform integration tests

RunPlayStudio/                 # macOS executable (SwiftUI, Swift Charts)
├── Sources/
│   ├── Commands/              # CommandRegistry, focused actions, shortcuts help
│   ├── Services/              # UI-adjacent services (library, PNG/video/comparison-video export, announcements)
│   ├── ViewModels/            # View state management (AppState, ReplayController, PNG/video/comparison-video export)
│   ├── Views/                 # SwiftUI views
│   └── 3D/                    # Legacy SceneKit prototype utilities (not the shipped map UI)
├── Resources/                 # Sample data and fixtures
└── Tests/
    └── RunPlayStudioTests/    # macOS-specific tests
```

### C++ route and analysis kernels

`RunPlayEngineCpp` is a C++23 foundation target. It exposes deterministic
engine identity (`runplay::engine_info`), a route value and inspection
contract, allocation-free geodesy primitives, the production combined
route-quality geometry
kernel, the production per-workout personal heatmap coverage kernel, and the
production constrained-DTW path solver for Route-Aware comparison, and the
production SegmentDetector window-search kernel:

- public-header discovery and C++23 compilation on macOS and Linux;
- Swift/C++ interoperability through an **internal** `RunPlayCore` adapter;
- native C++ tests and Swift integration tests;
- strict warnings, ASan/UBSan CI, and architecture-boundary validation;
- exact preservation of every `RoutePoint` field through a deterministic
  digest independently implemented in Swift and C++;
- production stages 2–4 of route quality through one bulk call;
- the production Route-Aware constrained-DTW path solve through one bulk call
  per alignment attempt;
- the production SegmentDetector candidate search — the five segment
  highlights plus the five fixed-distance personal-record windows — through
  one bulk call per detector invocation.

```text
Swift stage-1 ordered [RoutePoint]
    → contiguous RouteInputSample buffer
    + optional selection byte buffer
    + RouteQualityOutputSample output buffer
    → process_route_quality_geometry(...) noexcept
    → pure-Swift retained points / diagnostics / provenance
    → Swift source-speed validation and elevation
```

Inspection remains available for field-fidelity tests:

```text
Swift [RoutePoint]
    → contiguous RouteInputSample buffer
    → inspect_route_batch(const RouteInputSample*, size_t) noexcept
    → compact RouteBatchInspection
    → pure-Swift RunPlayRouteBatchInspection
```

Swift enumerates points in source order and uses the array offset as
`source_index`; point UUID ownership stays in Swift. Timestamp values are
exactly `Date.timeIntervalSinceReferenceDate` with no rounding. Optional values
use `std::optional<double>` and never use numeric sentinels.

Boundary ownership is explicit:

- Swift owns and keeps every contiguous buffer alive;
- C++ borrows buffers for one synchronous call through `std::span` internally;
- C++ never stores either pointer and allocates nothing proportional to the route;
- C++ writes exactly `sample_count` output entries on success and writes
  nothing on error;
- the Core adapter converts compact C++ summaries to pure Swift before imported
  C++ values are destroyed.

#### C++23 geodesy primitives

`Geodesy.hpp` provides allocation-free primitives equivalent to the Swift
`GeoDistance` implementation:

```cpp
inline constexpr double earth_radius_meters = 6'371'000.0;
struct LocalMeters final { double x_meters; double z_meters; };

[[nodiscard]] bool is_valid_coordinate(double, double) noexcept;
[[nodiscard]] double haversine_distance_meters(double, double, double, double) noexcept;
[[nodiscard]] LocalMeters project_lat_lon_to_local_meters(double, double, double, double) noexcept;
```

These are a literal migration, not an accuracy redesign. The Earth radius,
Haversine formula, projection coefficients, and operation order are unchanged,
including `degrees * pi / 180` evaluated left to right. There is no longitude
wrapping, ellipsoid, clamping, or third-party geodesic library. Existing
limitations are preserved: the projection does not validate, clamp, or wrap its
inputs and propagates non-finite values, and some exactly antipodal pairs round
the haversine term above 1 so the distance is NaN in both implementations.

Clang defaults to `-ffp-contract=on` while Swift never contracts, so the C++
implementation splits accumulations such that no statement holds both a
multiply and an add. The two implementations therefore agree bit for bit on one
platform; parity-test tolerance exists only for macOS/Linux libm differences.

#### Production combined route-quality geometry

`RouteQualityPipeline.hpp` exposes one bulk kernel for stages 2–4:

```cpp
[[nodiscard]]
RouteQualityPipelineSummary process_route_quality_geometry(
    const RouteInputSample* samples,
    std::size_t sample_count,
    RouteQualityGeometryPolicy policy,
    RouteQualityDistancePolicy distance_policy,
    const std::uint8_t* supplied_selection_by_sample,
    std::size_t supplied_selection_count,
    RouteQualityOutputSample* output_samples,
    std::size_t output_capacity
) noexcept;
```

Route size is bounded in Swift, not at the engine boundary.
`WorkoutImportResourceLimits.maxRoutePointCount` (1,000,000) is the product
limit, enforced by every importer and by a preflight in
`RouteQualityProcessor.process` before the native input buffer is built.
`max_route_input_samples` (1,250,000) is an internal safety ceiling 25% above
it, so `resource_limit` at the boundary means a Swift-side limit failed to run
rather than that a user's workout is too long.

Semantics:

- output index matches input index;
- isolated coordinate outliers are rejected; adjacent candidates are retained;
- implicit gaps and explicit source segments form contiguous final segments;
- supplied-distance validity resets per final segment;
- coordinate-derived steps reuse internal geodesy helpers;
- no distance is added across explicit or inferred boundaries;
- point identity and order are preserved.

**Swift performs route-size validation, basic field sanitization, sorting,
initial source-segment compaction, source-speed validation, elevation,
diagnostics translation, public models, and persistence.**

**C++ performs production outlier evidence, isolated-point rejection, implicit
gap inference, final segment compaction, supplied-distance policy, and
normalized cumulative distances through one bulk call.**

`RouteQualityProcessor` calls only `RunPlayRouteQualityBridge`. No scalar
per-point Swift/C++ production calls are allowed.
`scripts/validate-cpp-boundaries.sh` enforces that isolation mechanically.

Timelines, splits, projection services, and file parsers remain in Swift
`RunPlayCore`. Elevation-profile construction is already native (see
[ElevationProfile and WorkoutAnalysisContext](#elevationprofile-and-workoutanalysiscontext)).
Per-workout personal heatmap
route coverage is already native, and cross-workout heatmap aggregation stays
Swift by an explicit profiling-driven decision; see
[Personal Heatmap](#personal-heatmap). The Route-Aware constrained-DTW path
solve is already native, while alignment sample construction, direction
detection, blocks, diagnostics, quality, and aligned metrics remain Swift; see
[WorkoutComparisonService](#workoutcomparisonservice). C++ types never appear
in public `RunPlayCore` APIs.

`RunPlayCore` remains the only Swift-facing core API and continues to own
app-facing models, `Codable` compatibility, errors/diagnostics, actors,
filesystem persistence, schema migration, and Swift↔C++ value translation.

Each route operation must cross the engine boundary in one bulk call, never one
call per point. Platform and Studio must not traverse C++ containers or import
the engine directly.

Approved pointer boundaries:

- `const RouteInputSample*` input for route inspection
- combined route-quality geometry: const input samples, optional const
  selection bytes, and caller-owned `RouteQualityOutputSample*` output
- per-workout personal heatmap coverage: `const PersonalHeatmapRouteSample*`
  input samples and caller-owned `PersonalHeatmapCellIndex*` output. Unlike the
  per-sample boundaries, this one is capacity-negotiated: it writes
  `required_cell_count` de-duplicated cells on success, and writes nothing on
  `insufficient_output_capacity` so Swift can reallocate and retry. On success,
  Interop exposes only the written prefix to a private nonescaping closure and
  production counts directly from it; no pointer, C++ cell value, or per-workout
  Swift cell array escapes that lifetime.
- constrained-DTW path solving: `const RouteAlignmentCostSample*` primary and
  comparison inputs plus a caller-owned `RouteAlignmentDtwPathCell*` output.
  This is the only boundary that borrows two const input buffers in one call.
  It is not capacity-negotiated: a valid path never exceeds
  `primary_sample_count + comparison_sample_count + 1` cells, so Swift allocates
  that proven bound and an insufficient-capacity response is an engine contract
  violation. On any failure status the output buffer is left completely
  unchanged.
- segment detection: `const SegmentDetectionSample*` input samples plus a
  caller-owned `SegmentWindowCandidate*` output. Swift supplies the fixed
  ten-entry capacity and consumes exactly `candidate_count` entries on
  success (at most ten: the five segment-highlight kinds plus one candidate
  per personal-record window the route covers). Insufficient capacity is a
  contract violation, every failure leaves the output unchanged, and each
  internal distance-window search retains its per-search evaluation bound.
- elevation profile construction: `const ElevationProfileInputSample*` input
  samples plus a caller-owned `ElevationProfileOutputSample*` output. One
  output entry corresponds to one input route point. After validation the
  output buffer is the route-sized workspace; no route-sized native heap is
  allocated. Every failure leaves the output unchanged. One native call occurs
  per profile build. C++23 performs source altitude screening, spike and
  short-excursion rejection, supported rejected-sample interpolation, run
  classification, distance-domain smoothing, reliable interval tracking, and
  deadband-confirmed cumulative ascent/descent. Swift retains route-point
  UUIDs, public `ElevationProfile`/`ElevationProfileSample` models, all
  distance-query APIs, policy ownership, cancellation, diagnostics, and
  persistence.

#### C++ policy defaults

| Class | Guidance |
| --- | --- |
| Encouraged | value semantics, RAII, `std::vector` / `std::span` / `std::array`, `std::optional`, `std::expected` internally, `std::unique_ptr` when needed, `enum class`, `std::chrono`, ranges/algorithms, concepts |
| Needs justification | `std::shared_ptr`, raw non-owning pointers, `reinterpret_cast`, mutable globals, exceptions in engine logic, manual memory management |
| Forbidden at Swift boundary | uncaught exceptions, temporary borrowed views, ownership ambiguity, `std::pair`, `std::tuple`, `std::variant`, template-heavy public APIs, callbacks into Swift, per-element cross-language calls |

Boundary checks: `./scripts/validate-cpp-boundaries.sh`.
Native C++ tests: `swift test --filter RunPlayEngineCppTests
-Xswiftc -warnings-as-errors` through the portable SwiftPM harness, or
`./scripts/run-cpp-engine-tests.sh` directly (add `--sanitize` for ASan+UBSan).
External package consumption:
`swift build --package-path Tests/PackageConsumerSmoke`.

#### Swift/C++ interoperability note

SwiftPM attaches C++ target module maps to every transitive Swift dependent of
`RunPlayCore`. Those dependents must compile with
`.interoperabilityMode(.Cxx)` so the clang importer can parse C++ standard
headers. That build-setting requirement does **not** authorize
`import RunPlayEngineCpp` outside `RunPlayCore/Sources/Interop/`. Platform and
Studio keep pure Swift public APIs; the engine module remains an implementation
detail of Core.

### Commands and accessibility

Menu shortcuts are owned by `CommandRegistry` and `WorkoutViewCommands`, with
focused action bundles (`ReplayActions`, `LibraryActions`, `MapActions`) published
from the active workspace. Pure summary text lives in RunPlayCore so Linux CI can
test spoken semantics without AppKit. See
[accessibility-audit.md](accessibility-audit.md).


## PNG Summary Export

PNG summary export is a **data-driven card**, not a screenshot of the live window.

| Layer | Responsibility |
| --- | --- |
| **RunPlayCore** | `PNGSummaryExportConfiguration`, layout limits, `ExportSummaryCardModel` |
| **RunPlayPlatform** | `WorkoutMapSnapshotting` / `MKMapSnapshotter`, region planner, overlay composer, metric palette |
| **RunPlayStudio** | Configuration sheet, `PNGSummaryExportViewModel`, presentation model, export palettes, fixed-scale `ImageRenderer` |

Pipeline: prepare route lines with the same metric profile/line builders as the
live map → optional MapKit basemap snapshot → composite routes/markers → render
card at **1200×1600** with scale **1.0** → atomic save. Appearance is resolved
Light/Dark before rendering. Map failures preserve configuration and offer
Retry / Export Without Map. Map imagery is cached only in memory for identical
request keys and is never persisted.

## Personal Heatmap

The Personal Heatmap is a **derived, library-level** visualization. It is not
stored on each `RunWorkout` and does not bump analysis, normalization, or
library manifest versions.

| Layer | Responsibility |
| --- | --- |
| **RunPlayEngineCpp** | Per-workout coverage kernel: Web Mercator projection, grid-cell quantization, effective-segment gap breaking, Amanatides–Woo supercover traversal, per-workout de-duplication, deterministic cell ordering |
| **RunPlayCore** | `PersonalHeatmap*` models, `RunPlayPersonalHeatmapCoverageBridge` interop, `PersonalHeatmapBuilder` date filtering, adaptive resolution, cross-workout aggregation, and snapshot finalization. Interop consumes the caller-owned native output through a nonescaping closure and updates the Swift counts dictionary without a production per-workout cell array. `PersonalHeatmapProjection` / `PersonalHeatmapGridTraversal` remain as the public Swift reference implementation and parity oracle |
| **RunPlayPlatform** | `RouteMapArea` polygons and map-rect fitting for areas |
| **RunPlayStudio** | `PersonalHeatmapViewModel`, workspace mode, sidebar/menu entry, SwiftUI map fills |

### Intensity semantics

Primary heat is the number of **distinct included workouts** whose route
traverses a cell. Within one workout, loops and dense GPS samples contribute at
most once per cell. Intensity is log1p-normalized against the maximum aggregated
count so low-frequency cells remain visible.

### Gap safety

Rasterization only walks adjacent valid points in the same effective route
segment. Pause/resume, track boundaries, inferred gaps, and discarded invalid
coordinates never draw a corridor between segments.

### Adaptive performance

Default rendered-cell budget is **5,000** polygons. When the filtered cell count
exceeds the budget, the builder doubles cell size until the result fits. All
included workouts are preserved; cells are not randomly dropped. Effective cell
size is exposed in the snapshot and UI.

`PersonalHeatmapViewModel` always requests
`PersonalHeatmapConfiguration.defaultMaximumRenderedCellCount`, so the adaptive
loop bounds deterministic sorting and cell materialization to that budget in
every shipping configuration.

### Aggregation ownership

Cross-workout aggregation stays in Swift. The builder reserves its counts
dictionary with a bounded adaptive hint, consumes each caller-owned native
coverage buffer while that buffer is alive, and increments the dictionary
directly. The pointer and imported C++ cell type never escape Interop, and the
production path creates no per-workout `[PersonalHeatmapCellID]`. The
array-returning adapter remains available for parity and bridge tests.

`PersonalHeatmapCellID` mixes both signed X/Y coordinates into one 64-bit input
to Swift `Hasher`. That mixed word is neither persisted nor stable external
identity: equality, ordering, geographic meaning, and keyed `Codable` continue
to use the original coordinates. Reservation hints are capped Swift allocation
advice only; they never truncate aggregation or become a product/library limit.

The production-equivalent profiler at
`scripts/run-personal-heatmap-profile.sh` supports the ownership decision:

- the already-native per-workout coverage kernel dominates every
  production-reachable configuration;
- cross-workout counting is the largest remaining Swift cost, and that cost is
  Swift `Hasher` work plus dictionary growth rather than algorithmic work;
- caller-owned output allocation, including every capacity retry, remains too
  small to justify a new boundary;
- sorting and materialization are capped by the rendered-cell budget.

A whole-pass native aggregation call would require a new arbitrary
whole-library route-point limit — `WorkoutImportResourceLimits` bounds a single
workout, not a library — and would run uninterruptibly across the whole library,
losing per-workout cancellation. A per-workout call would require either a
retained native accumulator, which contradicts the contract that C++ retains
nothing between calls, or a Swift-owned open-addressed table plus a rehash
boundary. This bounded Swift phase addresses the measured cost without adding
any of those contracts. See [phase-plan.md](phase-plan.md).

#### Remaining-core hotspot profile conclusion

`scripts/run-remaining-core-hotspot-profile.sh` profiles the remaining active
production paths with production-equivalent Mode A/B decomposition, exact
output digests, a 5% accounting-residue gate, and statistical release timings.
Machine-specific milliseconds live only in profile output, not here.

**Completed boundary:** `SegmentDetector` now performs its bounded window search
through one bulk C++23 kernel per invocation.
The post-cutover analysis profile passes exact Mode A/B digests through the
product limit. Segment detection remains a material phase, but elevation is now
the largest isolated phase in direct analysis and route quality plus elevation
dominates normalization. Ordinary 1k-point workouts remain well under a
millisecond end-to-end.

**Completed boundary:** `ElevationProfile` multi-pass construction is production
C++23. Exact oracle parity preserves gap, spike, excursion, smoothing, and
deadband gain/loss semantics. SegmentDetector continues to consume the pure
Swift elevation snapshot after the native elevation build.

**Completed boundary:** route-metric numeric finalization now performs
deterministic distance-weighted lower/median/upper scale construction,
normalization, bucket assignment, coverage accumulation, and numeric summary
construction through one allocation-free C++23 bulk call per non-solid profile.
The Swift-owned output buffer is also the native sorting workspace and is
restored to source order before return. Swift retains raw metric extraction,
distance-domain smoothing, localized labels, public profile models,
availability and caching, cancellation, Platform line coalescing, UI state,
diagnostics, and persistence.

**Post-cutover decision:** no further performance migration is selected.
MovementProfile remains in Swift because its refreshed analysis share is too
small to justify another native boundary. The next phase is the mandatory final
portable-core cleanup unless new evidence identifies a concrete product-visible
regression or missing portable boundary.

**Intentional remaining Swift ownership:**

- importer decode (Foundation JSON / XMLParser / FIT binary framing);
- `WorkoutLibraryQueryService` over lightweight library entries;
- `RouteAlignmentSampleBuilder` and Swift post-DTW block/diagnostics work
  (DTW path solve is already native);
- route-metric extraction, smoothing, label formatting, public profile
  materialization, and Platform map-line presentation;
- public elevation models, distance queries, and SegmentDetector snapshot
  materialization;
- cancellation, identity, Codable models, and persistence.

**Why other candidates stay Swift:** MovementProfile remains below the threshold
for another native boundary; importer parsers are not
portable pure-numeric kernels; MetricSmoother alone is too small;
SplitCalculator is modest once context is shared.

Legacy SceneKit projection stays low priority unless it regains a shipped
caller. The portable-core migration ends with a mandatory cleanup phase
(transitional boundaries, oracles, sanitizers, package-consumer, docs).

Timings are machine-specific and live in benchmark and profile output, not in
this document.

### Trends workspace

Trends is a **derived, library-level** visualization of whole-workout summaries
over time. Like the personal heatmap it stores nothing per view open; unlike
the heatmap it never walks route points at view time either.

| Layer | Responsibility |
| --- | --- |
| **RunPlayCore** | `WorkoutTrends*` models (period, range, scope, summary row, period key, bucket, aggregation), `WorkoutTrendsSummaryRow.make` (summary-only row derivation), `WorkoutTrendsAggregator` (bucketing, range anchoring, gap semantics), `WorkoutTrendsScopeResolver` (scope → workout ID set through `WorkoutLibraryQueryService`), persisted raw ascent/descent totals in `RunSummary` at analysis time, `TrendsAccessibilitySummary` / `TrendsChartAccessibilitySummary` spoken summaries |
| **RunPlayPlatform** | None |
| **RunPlayStudio** | `TrendsViewModel` (filters, cancellable off-main aggregation, in-memory revision-keyed cache), `TrendsView` (Swift Charts panels, inspector, navigation), workspace/session/command wiring |

#### Derivation model

Rows derive purely from stored snapshot summaries and metadata — never from
route points and never by re-parsing source files — so building rows for the
whole library is linear in workout count. There is deliberately **no disk
sidecar**: `AppState` already holds
every stored snapshot in memory, so a parallel cache file would be a second
source of truth whose only job is defending against itself. Freshness comes
from the same in-memory revision-keyed cache pattern the heatmap uses; the row
revision is (id, analysis version, start date, recorded UTC offset).

The one value that route summaries did not previously carry is the **raw
ascent fallback**. That is persisted once at analysis time: `WorkoutAnalyzer`
adds `rawElevationGainMeters` / `rawElevationLossMeters` (sum of positive and
negative adjacent altitude deltas within one route segment, skipping missing
or non-finite samples) to `RunSummary`, and `analysisVersion` is now 6 so
existing libraries recompute on load. This is an extraction-stage linear sum
in Swift, deliberately in the same ownership bucket as raw pace/heart-rate
extraction rather than a C++ kernel: it runs once per analysis, is never on a
per-view path, and an engine boundary would add a pointer contract for no
user-visible gain.

#### Bucketing, ranges, and gaps

- Each run belongs to exactly one period: the period containing its canonical
  start **local date**. Runs crossing midnight or a week boundary count
  entirely in their start period.
- The local date resolves in the run's recorded UTC offset when the source
  format carried one (GPX/TCX/JSON capture the literal designator, `Z` being
  0); FIT logs UTC instants only, so those runs fall back to the system zone.
  `WorkoutMetadata.recordedUTCOffsetSeconds` carries the value.
- Weeks are ISO 8601 (Monday start; the key year is the ISO week-date year);
  months and years share Gregorian boundaries in the same calendar.
- "Last N months" includes whole periods: the anchor instant `now − N months`
  (display zone) resolves to its period and every period with a nominal key
  at or after the anchor's is included. The trailing in-progress period is
  included whole and annotated; the enumerated window is clamped to 5,000
  periods by dropping the oldest, and the enumeration itself runs backwards
  from the newest period so it never exceeds that bound.
- The window ends at the current period, extended by at most one period. That
  one period is what a run recorded in a zone ahead of the display zone needs;
  beyond it a row is clock skew or a corrupt date, and letting it set the end
  would push the real data out of the capped window. Rows outside the window at
  either end are counted in `outOfWindowRunCount` and disclosed in the spoken
  summary, never silently dropped.
- Trends state is **active time**: totals, aggregate pace (total active
  seconds ÷ total kilometres), and heart-rate weighting (active-time-weighted
  mean of run averages) never include pauses.
- Distance, active time, and run count are true sums (zero in empty periods).
  Pace, HR, and ascent are gaps (`nil`) when no contributing run carries the
  metric; mixed periods aggregate the runs that do and disclose contributor
  counts ("HR from 4 of 7 runs") in the inspector, spoken summaries, and chart
  accessibility values, so sparse periods cannot be misread as trends.
- Ascent per run uses corrected elevation when the summary carries a
  meaningful profile, else the persisted raw totals.

#### Scoping and navigation

Scope is entire library, the current All Runs query, or a smart collection;
the latter two resolve through `WorkoutLibraryQueryService` over lightweight
entries, so search text, filters, tags, favourites, and relative dates behave
identically to the All Runs table. Entering Trends for the first time in a
session while All Runs shows a smart collection preselects that collection
once; later manual scope choices are never overwritten. Clicking a bar/point
(or the keyboard/VoiceOver inspector button) navigates to All Runs filtered to
that period's bounds in the system zone, preserving manual search/tag scope;
over an active collection the date filter marks the working query Modified.
Mixed-zone libraries accept one display edge: a run recorded abroad near a
period boundary can contribute to a nominal period whose system-zone filter
excludes it.

Trends state (period, range, scope kind + collection) participates in session
restoration as of session version 3; older sessions decode with default
selections and the validator repairs raw values, dangling collections, and
unknown destinations.

### Personal Records

Personal Records is a **derived, library-level** table like Trends. Best
fixed-distance windows are computed once per workout in the same analysis
pass as segments (one native detection call produces both) and stored on the
snapshot as `RunWorkout.personalRecords`. The field is decode-tolerant and
**deliberately not gated on `analysisVersion`**: absence (`nil`) is the
backfill marker, while a non-`nil` value with zero windows means the run
attempted no window.

| Layer | Responsibility |
| --- | --- |
| **RunPlayEngineCpp** | The five extra fixed-window fastest searches (1 mile, 5 km, 10 km, half marathon, marathon) inside the existing single segment-detection bulk call; canonical window lengths live in engine constants so Swift record identity cannot drift |
| **RunPlayCore** | `PersonalRecordCategory`/`PersonalRecordWindow`/`WorkoutPersonalRecords` models, window finalization (HR averages, point ranges), `PersonalRecordsAggregator` (standing bests, strict-improvement progression capped at 10, longest run, corrected-else-raw biggest ascent), the resumable store-actor backfill, `PersonalRecordsAccessibilitySummary` |
| **RunPlayPlatform** | `RouteMapLineStyle.highlight` and gap-split `highlightedRangeLines` for the map emphasis overlay |
| **RunPlayStudio** | `PersonalRecordsViewModel` (scope, off-main aggregation, revision cache, inline backfill state), `PersonalRecordsView`, record click-through, Overview standing-record chips, session restoration (session version 4) |

Semantics:

- **Pause semantics match segments exactly.** Windows continue in cumulative
  distance and may span a recording gap; pace uses the active clock, so
  paused time never counts. Windows longer than the run are *not attempted*:
  the row shows no value (em dash / "not attempted"), never zero.
- **Standing bests and progression.** A record improves only on a strictly
  better effort; an exactly equal effort never replaces the earlier holder.
  The history list is the progression of set-or-beat events (oldest →
  newest, capped at the last 10), and the standing best is always its last
  event. Longest run uses summary distance; biggest single-run ascent uses
  corrected ascent with the raw adjacent-delta fallback — the same rule
  Trends uses.
- **Scoping.** Scope reuses `WorkoutTrendsScopeResolver` verbatim: entire
  library, the current All Runs query, or a smart collection, so a tagged
  subset such as "race" gets its own record tables. Entering Records while
  All Runs shows a smart collection preselects that collection on first open
  only, exactly like Trends.
- **Badges reflect only the current standing record, whole-library scope.**
  A run whose record was later beaten shows no Overview chip by design — its
  history lives in the Records progression. This is intended behaviour, not
  a stale-data bug.
- **One-off backfill.** Existing libraries never re-analyze at load: the
  backfill runs through `WorkoutLibraryStoreActor.backfillPersonalRecords`
  when the Records workspace first opens over snapshots missing records. It
  walks the whole manifest and reports progress against that total, skipping
  snapshots that already carry the marker, and honours task cancellation —
  whether it arrives between workouts or inside a detection — by ending the
  pass and returning the partial totals. Cancellation is never counted as a
  failure: completed snapshots stay saved, the interrupted workout keeps its
  unset marker, and the pass resumes on the next open. It yields between
  workouts so library operations interleave, and is idempotent — a second
  pass skips every workout that already carries the marker. Each computed
  snapshot is applied in memory as it arrives, but the library is not rebuilt
  per workout: entries and search documents derive from metadata and
  summaries, never from record windows.
- **Search cost.** Each fixed-window pace search is O(E log n) with
  E = ⌊(total − window)/step⌋ + 1 — driven by the *spare* distance beyond the
  window, not the window length (a marathon window on a marathon run is one
  evaluation). Swift's `RouteAnalysisBudget.boundedStep` raises each step to
  at least `distanceSpan / (maxEvals − 1)` before the native call, so a
  compliant configuration can never exceed the per-search budget: exhaustion
  degrades to a coarser step and a candidate is never silently dropped. The
  native `resource_limit` pre-check remains a contract-violation safety net.
- **Click-through.** Opening a record selects the workout, seeks replay to
  the window start, and sets a transient `highlightedWorkoutRange` rendered
  as a heavier same-hue route overlay (split per route segment, so it never
  bridges a pause geographically) and a translucent chart band. Whole-run
  records open the workout without a range. The highlight clears when
  another workout is selected and is never persisted.
- **Segments panel.** The panel still lists the original five segment kinds
  first, then any long record window (1 mile and up) this run actually
  attempted, shortest window first; windows longer than the run are absent,
  not "not attempted" rows. Each record row takes its own display priority
  and reuses its stored `PersonalRecordWindow` id, so the order does not
  depend on sort stability and the row keeps one identity across view
  updates.

Records state (scope kind + collection) participates in session restoration
as of session version 4; older sessions decode with the entire-library
default and the validator repairs dangling scope collections and unknown
destinations.

### Route grouping (Routes workspace)

Automatic route grouping clusters runs that follow substantially the same
route and shows progression on each route. It is derived library-level
state: membership lives in the manifest (schema **v4**), while geometry
never persists beyond each group's cached representative summary.

Two-stage matching, both owned by RunPlayCore:

1. **Stage 1 — candidate filter (pure Swift arithmetic).** Per-workout
   `RouteGroupingRouteFacts` (bounding box, endpoints, distance, valid point
   count, discarded-point count) are computed from stored route points. A
   pair is a candidate when the bounding boxes overlap with margin and one
   route's start is near either endpoint of the other (admitting reversed
   traversals). A historical distance-ratio bound was removed by
   measurement: with mutual coverage as the guard it is redundant for
   correctness, and on the 2,000-workout benchmark library it saved 1 of
   1,760 stage-2 solves — the bounding-box and endpoint tests do the
   filtering work.
2. **Stage 2 — shape confirmation over the existing constrained-DTW
   boundary.** The pair goes through `RouteAlignmentSampleBuilder` and the
   same one-bulk-call `RunPlayRouteAlignmentDtwBridge` solve used by
   Route-Aware comparison — there is no second DTW. A Swift scoring walk
   over the returned path accumulates **diagonally matched** distance per
   side and advance-weighted separations, exactly mirroring how the aligner
   derives its diagnostics.

Decision thresholds (all in `RouteGroupingPolicy`, documented values):
**mutual coverage ≥ 0.90**, distance-weighted **median separation ≤ 35 m**,
**p90 separation ≤ 100 m**, at a grouping unmatched budget of **100 m**.
Mutual coverage is matched distance ÷ total distance evaluated on BOTH
routes — the smaller of the two per-side coverages — from the single
existing solve. It is the discriminating axis and is deliberately stricter
than comparison acceptance; separation stays at the comparison "good" band
because it is dominated by GPS quality — a false merge silently corrupts a
progression chart while a false split is visible and fixable with Merge.

**Containment.** A route that wholly contains another is not the same
route, whether the extra distance is a spur, a warm-up, or a longer
finish; the two runs do not group. Mutual coverage is the guard: the
contained side can be fully covered while the containing side covers at
most shared/total, so containment pairs cap at their geometric ratio
(1/length-ratio) no matter how cleanly the shared section aligns, and no
budget or separation setting can lift them above it. This is a deliberate
product decision that reverses the original plan's superset rule
(loop-plus-spur grouping with the loop); the measured grid behind the
(budget, threshold) pair is `RouteGroupingMeasurementTests`
(`RUNPLAY_ROUTE_GROUPING_MEASURE=1`). At 100 m / 0.90 the margins are
0.038 below the line (loop-plus-spur at 0.862, the closest reject) and
0.050 above (a 2 km identical pair at 0.950, the closest accept; the
engine's 10 %-of-length fraction cap makes short routes the coverage
floor, which is why the grid includes one). Prefixes never fail to solve
at tight budgets — they solve with mutual coverage pinned at
shorter/longer and, when the shared section is small, separation blown
out (5-of-10 km: coverage 0.500, p90 ≈ 4.5 km). 40 %-shared loops are
rejected by separation (median 400–520 m) at every budget. The recovery
path for a genuine containment pair the user wants unified is the manual
merge control.

**Opposite direction** runs group with their route (no user toggle). The
coarse ordered-sequence direction probe — the same one comparison uses —
orients the solve, and the Routes detail list marks reversed members (a
hilly loop run backwards has a different pace profile).

**Representatives.** The effective representative of a group is a pure
function of its member set: highest route quality (fewest discarded
coordinate points, then densest sampling), earliest canonical date
tiebreak, with a user pin overriding until the pinned workout no longer
clusters into the group. Because it never depends on join order,
chronological incremental assignment and a full re-cluster produce
identical partitions. A cached `WorkoutRouteGroupSummary` (representative
identity + stage-1 facts) persists with each group so a new import matches
only against representatives without loading the library; drift is repaired
by re-cluster.

**Durability and revision discipline.** A workout's assignment record is
the nil marker: *absence* means assignment has not run and a later pass
picks it up (the records-backfill argument); a present record with a `nil`
group ID means evaluated and deliberately ungrouped (below participation
minimums, or removed by the user — never auto re-added). New imports assign
asynchronously after the commit; an interrupted pass simply leaves its
workouts pending. The route-groups library revision bumps once per pass,
never per workout; per-item progress lives in the Routes view model.
Deletion repairs membership transactionally in the store actor.

**Naming.** No geocoding — the privacy model forbids it. Unnamed groups
derive a descriptive default from the representative's own geometry
("5.2 km Loop" versus "10.1 km Route" by start-to-finish closure); users
can rename at any time.

Manual controls: rename, merge two routes, remove a run from a route
(evaluated-nil marker), and pin a representative. A full re-cluster action
replays the greedy rule chronologically with progress and cancellation,
replaces the manifest in one atomic write (cancelled or failed passes leave
the previous groups untouched), and carries over user names and pins whose
referenced workouts still cluster together.

The All Runs query filter and the Personal Heatmap filter row both gain a
"route" restriction; the filter evaluates `WorkoutLibraryEntry.routeGroupID`
through the ordinary query service and is saved-query compatible. Routes
state participates in session restoration as of session **v5**
(destination only — the selected route is a transient table selection).

`scripts/run-route-grouping-benchmark.sh` compares stage-1 candidate
filtering against brute-force all-pairs matching on a 2,000-workout
synthetic library, asserting both produce identical groups.

### Workspace navigation

`AppWorkspaceMode` is `.workout`, `.comparison`, `.personalHeatmap`,
`.trends`, `.personalRecords`, `.routeGroups`, or `.workoutLibrary` (All
Runs) — mutually exclusive. Selecting a workout leaves heatmap; entering comparison leaves
heatmap; heatmap calculation runs off the main actor and does not block normal
library interaction beyond heatmap-local loading indicators.

### Library-level revision discipline

Derived, library-level workspaces invalidate through lightweight revision
tokens rather than by observing mutations: the Personal Heatmap cache key,
the Trends request key, and the workout-detail records revision
(`AppState.personalRecordsLibraryRevision`). One rule governs all of them:
**a revision changes once per semantic pass, never per item inside a pass.**
A backfill that computes records for N workouts mutates the in-memory
library N times but bumps the revision exactly once, when the pass
finishes; a per-item bump would make a visible view re-derive the whole
library once per completed workout — quadratic work during one pass and
visible re-render churn. This shape has now been corrected twice (heatmap
refresh coalescing, the records backfill bump); treat it as a rule, not a
per-feature decision. Progress a consumer must see per item (import counts,
backfill progress) belongs to that feature's own published state, never to
library-wide invalidation tokens.

### Application scene and session restoration

`RunPlayStudioApp` owns one stable-ID SwiftUI `Window`, one `AppState`, and one
`AppSessionController`. `ContentView` is an injected root view; it does not
construct a second production coordinator. Closing and reopening the main
window in the same process reuses the app-owned state, and the scene is left on
native macOS restoration for frame, minimise, zoom, and full-screen behavior.

The logical desktop context is separate from `WorkoutLibraryManifest`. The
Studio-owned `AppSessionSnapshot` is stored as bounded, sorted-key JSON at
`Application Support/RunPlayStudio/session.json` through the actor-backed
`FileAppSessionStore`. It contains only restorable values: destination, workout
tab/map presentation, manual All Runs query, active smart collection and its
optional modified working query, heatmap filters, comparison peer/distance/alignment mode/aligned progress,
paused replay scalars, and sidebar visibility. It never contains route points,
map images, caches, query result IDs, selections, sheets, alerts, operations,
or a playing flag.

Startup is library-first: the manifest and organisation load first, then the
session is decoded, validated against lightweight loaded IDs/policies, applied
once, and only then made active for writes. Invalid or missing references fall
back to a usable workout/manual-library state without an alert. Structural
changes debounce; replay callbacks are throttled and pause/inactive/close/
termination paths flush. A failed library mutation does not publish a session
reference until the committed in-memory state is available.

### Native route metric coloring

Single-workout Apple Maps routes can be colored by Solid, Pace, Heart Rate, or
Corrected Elevation. `RouteMetricProfileBuilder` (Core) is the only source of
interval metrics, distance-weighted relative scales, and palette-independent
buckets. `RouteMetricMapLineBuilder` (Platform) coalesces buckets into a bounded
set of `RouteMapLine`s. Studio’s `WorkoutRouteMapViewModel` caches results off
the main actor and does not rebuild on replay ticks. Its initial availability
probe returns reusable metric profiles, so the selected metric is not built
twice; only lightweight availability remains cached for later mode switches.

For every non-solid profile, Swift performs raw metric extraction and
distance-domain smoothing. Pace and heart-rate then make exactly one
`assign_route_metric_scale_buckets` call with caller-owned input, typed
eligible workspace, and output buffers. C++23 filters eligible weighted
samples into the workspace, constructs the deterministic numeric scale,
normalizes values, assigns buckets, and returns coverage/count summaries
without route-sized heap allocation, retained pointers, or output-buffer
type-punning. Corrected elevation intentionally finalizes scale and buckets
in Swift (`RouteMetricScaleBucketSwiftFinalizer`) because same-machine
production A/B showed a native regression above the hard gate; that is
mode-owned ownership, not an error-driven fallback. Policy `bucket_count` and
output `bucket_index` use `std::int64_t` so the public Swift `Int` domain is
preserved. Valid intervals may carry positive-infinite weights (coverage may
be `+infinity`); only finite positive weights contribute to weighted quantiles.
When a scale is known to be impossible after the read-only validation pass,
the native kernel initializes the output in source order, leaves the workspace
untouched, and performs no sort. Swift then creates localized labels and
public intervals in source order. Solid mode makes no native call. Platform
hysteresis, adaptive chunking, and line coalescing are unchanged.

Comparison maps keep primary blue / comparison orange identity. The personal
heatmap retains its own density palette. Missing HR is neutral no-data, not a
median fill. Elevation uses `WorkoutAnalysisContext.elevationProfile` only and
requires that profile to be meaningful. Single-point route segments remain as
no-data map-fitting placeholders without being passed to `MapPolyline`.
Preference storage is UI-only (`@AppStorage`); no workout migration.

### WorkoutImporting Protocol

All importers conform to `WorkoutImporting`:

```swift
public protocol WorkoutImporting {
    var supportedExtensions: [String] { get }
    func importWorkout(from url: URL) throws -> RunWorkout
}
```

The `WorkoutImporterFactory` dispatches by file extension. The SwiftUI file picker allows generic data files so `.tcx` and `.fit` files remain selectable even when the system does not declare dedicated UTIs; unsupported extensions are rejected by the importer factory.

### FIT activity decoding

`FITParser` independently decodes the FIT binary stream into ordered standard
message values before `FITDecoder` interprets one running activity. The parser validates
header/file CRCs, definition architecture and field types, compressed timestamp
headers, invalid sentinels, and bounded resource use. It retains file-ID,
record, event, lap, session, activity, and device-info messages in source order.
`FITDecoder` selects one
unambiguous GPS-bearing running session, filters its records and timer events,
and assigns `routeSegmentIndex` values so normalization, analysis, replay, and
map rendering do not bridge pause/resume gaps. The implementation targets common
running activities from Garmin FIT SDK Profile 21.205.0; developer metrics and
other unsupported FIT profile features remain skipped rather than interpreted.
Selected-session `total_elapsed_time` and `total_timer_time` are validation
signals only. Route timestamps and timer-derived segment indexes remain the
cross-format source of truth. A difference greater than five seconds or two
percent of the route-derived value, whichever is larger, produces an import
warning without replacing the route result.

### RouteQualityProcessor

`RouteQualityProcessor` is the platform-neutral, local-only normalization
boundary. Importers choose a distance policy and then hand raw points to the
same ordered stages:

1. validate coordinates and optional numeric fields, normalize point order and
   elapsed values, and discard invalid source speed/pace samples;
2. identify an isolated interior coordinate spike only when both adjacent legs
   imply excessive speed, the direct neighbour bridge is plausible, and the
   detour is both materially longer and sufficiently distorted;
3. introduce an implicit segment boundary only when a large relocation is
   supported by implausible speed or a long interval and the following points
   form a coherent cluster;
4. normalize cumulative distance without adding distance across explicit or
   inferred segment boundaries and record per-segment provenance;
5. sanitize altitude for analysis without replacing finite source altitude on
   `RoutePoint`;
6. smooth each continuous, non-missing altitude run in the distance domain;
7. calculate threshold-confirmed ascent and descent independently per run; and
8. return retained points, an aligned `ElevationProfile`, persisted diagnostics,
   distance provenance, and non-fatal warnings.

`RoutePointSanitizer` remains a compatibility entry point and delegates to this
processor. Existing explicit route segments are authoritative. First/last
points and adjacent spike candidates are retained because they lack the
neighbourhood evidence required for conservative removal. Invalid or ambiguous
signals fall back to valid-coordinate behavior rather than deleting a route.
No map matching, routing, network elevation, telemetry, or source-file rewrite
is involved.

### RouteQualityPolicy defaults

All tunable route and elevation thresholds live in `RouteQualityPolicy`. The
running defaults deliberately favour retention:

| Policy value | Default | Role |
| --- | ---: | --- |
| Maximum plausible running speed | 12 m/s (43.2 km/h) | Evidence for coordinate discontinuities, never a sole rejection rule |
| Maximum source speed | 15 m/s (54 km/h) | Rejects impossible device speed so normalized geometry can derive a replacement |
| Stale zero-speed movement threshold | 1 m/s | Treats a recorded zero as missing when normalized movement clearly continues |
| Maximum stationary source speed | 1 m/s | Treats a positive device speed as stale when normalized geometry is stationary |
| Maximum source-speed/geometry disagreement | 4× | Rejects a supplied speed that materially disagrees with its normalized step |
| Maximum useful horizontal accuracy | 100 m | Poor accuracy can support a spike decision only when neighbours are better |
| Coordinate-spike minimum excess / distortion | 200 m / 3× | Requires a substantial detour through an isolated candidate; good neighbour accuracy may halve only the excess requirement |
| Implicit-gap minimum jump / long interval | 200 m / 120 s | A long interval is supporting evidence only when the route also relocates |
| Long-gap cadence discontinuity | 3× | The suspected gap must be at least three times the resumed sampling cadence, avoiding false gaps in uniformly sparse tracks |
| Relocated-cluster confirmation | 3 points | Uses time-derived plausible speed when timestamps are valid; falls back to a 200 m maximum step only when timing is unavailable |
| Legacy distance inference tolerance | max(20 m, 5% of geometry) | Preserves a legacy non-GPX series as device-supplied only when it materially differs from raw geometry |
| Plausible altitude range | -500...9,000 m | Preserves below-sea-level routes while rejecting impossible values |
| Altitude-spike evidence | 35 m deviation, neighbours within 12 m, at most 150 m travelled span | Rejects only a locally unsupported interior or one-sided endpoint vertical spike |
| Short altitude-excursion evidence | At most 2 samples, each at least 100 m from the returned baseline, at most 150 m travelled span | Rejects only an extreme, tightly bounded receiver plateau while retaining sustained terrain changes |
| Elevation smoothing radius | 15 m (30 m full window) | Makes smoothing stable across sampling rates while preserving run endpoints |
| Minimum reliable altitude run | 2 samples | A lone sample may remain displayable but cannot produce meaningful gain/loss |
| Gain/loss deadband | 3 m | Confirms trend reversals before committing ascent or descent |
| Elevation-highlight window | 20% of total distance, clamped to 100...1,000 m | Defines one comparable continuous window for biggest climb/descent |
| Elevation-highlight evaluation step | max(25 m, window / 10) | Bounds window evaluations while retaining useful distance resolution |
| Cancellation stride | 2,048 points | Bounds cooperative cancellation latency in long processing loops |

### Distance-source precedence and provenance

A complete, finite, non-negative, monotonic device-distance series is preferred
when the importer can establish it. It is rebased at every compact segment
boundary and is never allowed to decrease. FIT evaluates supplied distance per
segment; TCX and JSON preserve it only when the complete supplied series is
valid. GPX derives distance from retained coordinates. Invalid or missing
series fall back to Haversine geometry after spike removal, and neither path
adds a jump across a gap.

`RouteDistanceSource` records the normalized workout as coordinate-derived,
device-supplied, mixed, or legacy-unknown. `RouteDistanceProvenance` records the
decision for each compact segment. Persisting both prevents a later migration
from guessing away a valid device series. Legacy snapshots without provenance
use a conservative source-aware inference: GPX remains coordinate-derived;
other complete monotonic series are retained only when they materially differ
from raw geometry.

### ElevationProfile and WorkoutAnalysisContext

`RoutePoint.altitudeMeters` is the finite altitude read from the source. The
processor does not overwrite it with corrected data. `ElevationProfile` is a
one-to-one derived view that exposes corrected altitude, source-rejection state,
cumulative ascent/descent, corrected altitude at cumulative distance, and
ascent, descent, or signed change over a distance range.

Each continuous non-missing altitude run is processed independently. Broad
range validation first rejects impossible values. Local checks can then reject
one unsupported interior or one-sided endpoint sample, or an extreme plateau of
at most two interior samples, only when the comparison baseline agrees and the
candidate occupies at most 150 m of travelled normalized distance. This
travelled span preserves legitimate switchbacks whose endpoint coordinates
happen to be close. A single rejected interior sample can be filled only from
its immediate reliable neighbours in the same segment; rejected endpoints and
adjacent rejected samples remain gaps. A centred rolling average then uses a
15 m distance radius and keeps reliable run endpoints. Missing spans and route
boundaries remain gaps. Runs shorter than two samples keep their sanitized
source values but return no meaningful gain/loss.

Gain and loss use a 3 m trend-reversal deadband. Minor oscillations do not
commit ascent or descent; a sustained trend is included, and a confirmed
reversal commits the prior trend exactly once. This is threshold-confirmed
cumulative ascent/descent, not a sum of every positive or negative adjacent
sample.

`WorkoutAnalyzer` creates one immutable `WorkoutAnalysisContext` containing the
profile and its `WorkoutTimeline`, then shares it with summary, split, and
notable-segment calculation. Biggest climb/descent evaluates a window equal to
20% of route distance clamped to 100...1,000 m, stepping by the larger of 25 m
or one tenth of the window. It selects the largest threshold-confirmed
ascent/descent only when the full window has continuous reliable elevation; it
never uses raw endpoints or bridges a gap. UI and platform code receive the
same immutable profile, with `AppState` retaining context values by workout
rather than using a global mutable cache. Charts, route colouring/projection,
comparison, replay metrics, and exports therefore use the same correction.

### MovementProfile

`MovementProfile` is another immutable analysis product created from normalized
route points and the authoritative `WorkoutTimeline`. It classifies same-segment
intervals as moving, stopped, paused, or uncertain using geometric speed,
displacement, cumulative distance, dwell time, and hysteresis. A resumed state
requires sustained evidence by duration or distance. Paused intervals remain
owned by `WorkoutTimeline` and never count as moving or stopped. Uncertain
active time counts as moving. Sparse or irregular timing uses the conservative
fallback `moving = active`, `stopped = 0`; compact `MovementDiagnostics` are
persisted while detailed interval state is derived at runtime.

JSON summary export carries normalization version, route-distance provenance,
quality diagnostics, warnings, and an `elevationAnalysis` description. Segment
JSON pairs `elevationMetric` with `correctedElevationValueMeters`; corrected
ascent/descent are positive magnitudes matching the UI subtitle, while the
legacy `elevationDeltaMeters` field remains a signed compatibility value. Split
CSV uses `Corrected_Elevation_Gain_m`; segment CSV pairs `Elevation_Metric` with
`Corrected_Elevation_Value_m`; and PNG summary labels use `Corrected Gain` and
`Corrected Loss`. Raw route-point altitude remains source data in snapshots.

### WorkoutTimeline

`WorkoutTimeline` is the platform-neutral clock and distance authority consumed by
`WorkoutAnalyzer`, `SplitCalculator`, `SegmentDetector`, `PlaybackEngine`,
`WorkoutComparisonService`, and export models. Its elevation APIs delegate to
the `ElevationProfile` supplied by the shared analysis context rather than
maintaining a raw-delta implementation.

- elapsed time is the final timestamp minus the first timestamp, falling back
  to normalized per-point elapsed values only when timestamps do not span;
- active time sums positive adjacent deltas within one route segment; the
  timestamp-free fallback treats elapsed time as active because it cannot infer
  pauses;
- paused time is elapsed minus active;
- distance sampling returns both clocks and never interpolates geography across
  a segment boundary;
- duplicate-distance range starts use the resumed point, while range ends use
  the pre-pause endpoint;
- replay lookup returns the latest real point whose elapsed time is at or before
  the replay clock.

Global kilometre splits and pace windows may span route segments because their
distance axis is cumulative. Primitive time, elevation, smoothing, and
coordinate interpolation remain segment-local, so no synthetic cross-gap
sample is created. A split may aggregate corrected ascent from multiple
continuous runs while interpolation remains confined to each run.

### Workout library persistence

### All Runs library browser

The All Runs workspace (`AppWorkspaceMode.workoutLibrary`) is driven by
`WorkoutLibraryViewModel`. Lightweight `WorkoutLibraryEntry` rows and
in-memory `WorkoutLibrarySearchDocument`s support search, filters, and sort
without iterating route points. `WorkoutLibraryQueryService` runs filtering and
sorting off the main actor with cooperative cancellation and stale-result
suppression. All Runs filters never change Personal Heatmap inputs.

The sidebar no longer lists every workout. `WorkoutLibrarySidebarPolicy` caps
Favourites (8) and Recent (10, excluding all favourites), with a
one-row Selected Run section when the selection is outside those bounds.

Manifest schema version **3** stores `favoriteWorkoutIDs`, ordered `tags`,
`tagAssignments`, and `smartCollections`. Version-1/2 manifests decode with empty
organisation fields; order, selection, and favourites are preserved. Tags are not
written into workout snapshots. Smart collections store `WorkoutLibrarySavedQuery`
(no membership IDs); relative date filters resolve when opened.
`WorkoutLibraryStoreActor.setFavorite` and `updateWorkoutMetadata` persist
favourites and editable name/notes without rerunning analysis.

`WorkoutLibraryStoring`, `FileWorkoutLibraryStore`, and
`WorkoutLibraryManifest` live in `RunPlayCore`. The store writes complete
normalized workout snapshots beneath Application Support using atomic writes.
`RunPlayStudio` supplies the production root URL and applies background load
results to `AppState`; bundled demos remain SwiftPM resources rather than user
library entries.

`RunWorkout.normalizationVersion` versions route-point normalization separately
from `analysisVersion`. Missing fields decode as legacy version `0`. During
actor-isolated loading, migration first decodes the compatible source model,
then upgrades normalization when required, builds the shared context,
recomputes analysis, and atomically replaces the snapshot. An analysis-only
upgrade may preserve already-current normalized route points. Current snapshots
are not rewritten on every launch.

Normalization preserves workout identity, metadata, source, retained
route-point IDs, library order, and selection; deliberately rejected points are
removed and segment indexes are compacted. A failed upgrade write leaves the
original disk snapshot intact, keeps the upgraded or decoded workout visible in
memory, reports a library warning, and retries on the next launch. The manifest
schema does not change.

### Performance and cancellation

Quality processing uses compact segment ranges, rolling distance windows,
reserved arrays, binary-search distance sampling, and linear timestamp-run
resolution. Sorting within source segments bounds normalization at O(n log n).
With `runningDefault`, coordinate, distance, smoothing, and cumulative-profile
work is linear; neighbourhood confirmation remains O(n × k), where the policy
keeps `k` to at most three relocated-cluster points or two altitude-excursion
samples. No stage scans the full route once per point, and no unsafe global
cache is introduced.

Distance-stepped split, segment, comparison, and chart work uses a fixed
`RouteAnalysisBudget`: at most 100,000 evaluations, scaled to eight evaluations
per route point with a minimum budget of 1,000. Impossible split cardinality is
returned as unavailable instead of allocating an unbounded result.

Long processor, elevation, and derived-analysis loops check cancellation.
Interactive import propagates `CancellationError` instead of converting it to a
parse failure. Analyzer work is assembled in a local copy and assigned only
after quality, summary, splits, and highlights complete, while persistence
checks cancellation before beginning the transaction. A cancelled pass
therefore cannot expose a partially analyzed workout or leave a partial library
entry. Synchronous library migration uses the same deterministic processor
without task cancellation because its recovery path must return every decodable
workout.

### GeoDistance

Platform-neutral distance calculation using the Haversine formula, replacing CoreLocation:

```swift
public enum GeoDistance {
    static func distanceMeters(fromLat: Double, lon: Double, toLat: Double, lon: Double) -> Double
    static func isValidCoordinate(lat: Double, lon: Double) -> Bool
}
```

### RoutePointInterpolator

Distance-based interpolation helpers used for route coordinates and chart
metrics. Pause-aware clocks and split boundaries use `WorkoutTimeline` instead:

```swift
public enum RoutePointInterpolator {
    static func point(at distance: Double, in points: [RoutePoint]) -> RoutePoint?
    static func scenePoint(at distance: Double, in points: [RouteScenePoint]) -> RouteScenePoint?
    static func firstIndex(atOrAfter: Double, in: [RoutePoint]) -> Int?
    static func lastIndex(atOrBefore: Double, in: [RoutePoint]) -> Int?
    static func averageHeartRate(in: [RoutePoint], from: Double, to: Double) -> Double?
    static func elevationGain(in: [RoutePoint], from: Double, to: Double) -> Double?
}
```

The `elevationGain` compatibility entry point delegates to `ElevationProfile`;
it does not maintain an independent raw-altitude delta algorithm.

### WorkoutComparisonService

Distance-mode comparison remains equal cumulative distance. Route-Aware
comparison is a separate optional path implemented by
`ConstrainedDynamicTimeWarpingAligner` and owned at the UI boundary by
`ComparisonViewModel`.

```swift
public struct WorkoutComparisonService {
    public func compare(primary: RunWorkout, comparison: RunWorkout) -> WorkoutComparisonSummary
    public func compareSplits(primary: RunWorkout, comparison: RunWorkout) -> [SplitComparison]
    public func compareRecordedLaps(primary: RunWorkout, comparison: RunWorkout) -> [RecordedLapComparison]
    public func compareMetricsOverDistance(primary: RunWorkout, comparison: RunWorkout, sampleIntervalMeters: Double = 100) -> [ComparisonMetricPoint]
    public func commonDistance(primary: RunWorkout, comparison: RunWorkout) -> Double
    public func metricsAtDistance(_ distance: Double, primary: RunWorkout, comparison: RunWorkout, primaryScenePoints: [RouteScenePoint], comparisonScenePoints: [RouteScenePoint]) -> ComparisonDistanceMetrics
}

public protocol RouteComparisonAligning: Sendable {
    func align(
        primary: RunWorkout,
        comparison: RunWorkout,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        policy: RouteAlignmentPolicy,
        isCancelled: @Sendable () -> Bool
    ) throws -> RouteAlignmentSnapshot
}
```

**Distance mode** clamps metric series to the common distance, filters
non-finite metric values, handles missing heart-rate/elevation data, and
returns warnings instead of crashing on weak comparisons. Summary comparison
distinguishes elapsed, active, paused, active-pace, and elapsed-pace deltas.
At selected distance, `WorkoutTimeline` supplies elapsed and active time plus
cumulative active pace; route coordinates still use segment-local
interpolation. Runs with materially different pause durations receive an
informative warning. Recorded laps are paired by ordinal only and are never
presented as route-aligned intervals.

**Route-Aware mode** matches geographic route shape with constrained DTW:

- segment-aware resampling in distance space (preferred 20 m, cap 2 000 samples)
- shared local metre-space origin (same policy family as comparison projection)
- geometry-only point cost (spatial separation + heading + progress); never pace/time/HR/elevation
- Sakoe–Chiba-style band, warp-run caps, bounded open prefix/suffix
- opposite-direction probe rejects cumulative-time alignment when reverse is preferred
- gap-preserving alignment blocks; mapping never interpolates across blocks
- matched-section clocks start at the current block’s start anchor
- quality: Excellent / Good / Limited / structured unavailable reasons
- complexity O(samples × bandWidth); slider lookup does not recompute DTW
- in-memory cache only; alignment paths are never written to disk

The path solve itself is native. The split is:

| Layer | Responsibility |
| --- | --- |
| **RunPlayEngineCpp** | Bounded band-packed constrained-DTW path solve: band radius, unmatched prefix/suffix expansion, packed row layout, band-cell budget validation, geometry-only point cost, open-beginning seeding, constrained transitions with fixed diagonal → primary-only → comparison-only tie priority, consecutive-warp capping, open-suffix endpoint selection, deterministic path reconstruction |
| **RunPlayCore** | `RouteAlignmentSampleBuilder` compact alignment samples, route-direction detection, `RunPlayRouteAlignmentDtwBridge` interop and path validation, alignment blocks and anchors, diagnostics and quality classification, public alignment models |
| **RunPlayStudio** | `ComparisonViewModel` cache, task lifecycle, request-generation stale-result suppression, Compare/Map/Chart UI |

Bounds and boundary semantics:

- at most **2,000 samples per route** (`RouteAlignmentPolicy.maximumSamplesPerRoute`)
  and at most **4,000,000 band cells** (`maximumBandCells`), the latter checked
  as an estimate before allocation and exactly after the packed layout is built;
- **one native call per alignment attempt**; no call per dynamic-programming row
  or cell, and no callback into Swift;
- both inputs and the path output are Swift-owned buffers borrowed
  synchronously; C++ retains no pointer;
- **on any failure status the output buffer is left completely unchanged**;
- cancellation is checked before and after the native call and during conversion
  and output translation, never inside the native call;
- `resource_limit` surfaces as `.unavailable(.resourceLimit)` and `no_path` as
  `.unavailable(.routesTooFarApart)`; contract violations surface as
  `.unavailable(.algorithmFailure)`.

Whole-workout summary cards, kilometre splits, and recorded laps remain
independent of alignment mode.

Replay remains on elapsed time, so its total duration equals summary elapsed
time. Inside a route gap the clock advances while the marker, distance, point
metrics, and active time remain at the stop endpoint. The resume point appears
only at its exact timestamp; no pause coordinates are synthesized.

### RouteMapCanvas

`RouteMapCanvas` is the shared SwiftUI MapKit surface for single-run and
comparison maps. It owns a `MapCameraPosition`, draws `MapPolyline` and
`Annotation` content, and exposes one 2D/3D camera toggle plus native MapKit
zoom controls. The 2D/3D state changes the same map camera:

- one realistic-elevation map style in both modes
- `MapCamera.pitch` of 0° versus a pitched perspective

`RouteMapContent` filters invalid coordinates, computes fitting bounds, and
interpolates selected-distance markers without introducing another renderer.

## Dependencies

### Apple Frameworks Used (macOS targets only)

- **SwiftUI**: App UI and views
- **MapKit**: Platform route/map data and one SwiftUI map with top-down and pitched presentations
- **AVFoundation**: File-backed H.264 route-replay encoding and validation
- **Swift Charts**: Pace, elevation, heart rate charts
- **SceneKit**: Legacy prototype utilities retained internally; not the shipped map surface
- **UniformTypeIdentifiers**: File import
- **Foundation**: Parsing and models

### Platform-Neutral (RunPlayCore)

- **Foundation**: Parsing and models
- **FoundationXML**: XML parsing on Linux (conditional import)

### Third-Party Dependencies

**None** — MVP uses only Apple-native frameworks.

## Future Considerations

- HealthKit for direct Apple Health import


## Strava bulk-export archive import

- **RunPlayCore** owns archive-independent candidate models, RFC 4180 CSV parsing,
  GZIP envelope decoding, path validation, sport policy, `WorkoutImportInput`
  data importers, `WorkoutImportProvenance`, and staged batch library APIs.
- **RunPlayPlatform** owns ZIP access via vendored ZIPFoundation 0.9.20,
  SHA-256 content hashing (CryptoKit), and `StravaArchiveService` (actor).
- **RunPlayStudio** owns the file picker, review/progress/report sheet, and
  AppState orchestration. Archive parsing never runs on `@MainActor`.
- Persistence uses a private `.staging/<batch-id>/` directory, then a single
  atomic manifest commit. The personal heatmap refreshes once after commit.


## Multi-session FIT import

- **RunPlayCore** owns everything FIT: `FITSportPolicy` (one classifier for scan
  and import), `FITSessionAttribution` (boundary resolution, shared-boundary
  ownership, overlap detection, and the bounded attribution walk),
  `FITSessionMessageIndex` (one-pass record/event/lap buckets per container),
  `FITSessionIdentity`, `FITMultiSessionImportPolicy`, and the
  `FITSessionImportService` actor implementing `FITFileScanning` and
  `FITSessionBatchImporting`.
- `FITImporter.buildSession(index:sessionIndex:suggestedName:provenance:)` is the
  single workout builder. The direct importer resolves the existing
  single-workout selection policy and then delegates to it, so direct and batch
  import can never drift apart. `FITDecoder.decodeRawResult(index:sessionIndex:)`
  is the explicit decode-by-index entry point; no global decoder selection state
  exists.
- **RunPlayPlatform** gains no FIT semantics. It supplies only
  `CryptoKitContentDigest`, a `ContentDigesting` conformance, because
  `RunPlayCore` must build on Linux where CryptoKit is unavailable and the
  repository forbids hand-rolled hashes.
- **RunPlayStudio** owns `FITSessionImportSession` (main actor) and
  `FITSessionImportView`. `AppState.importWorkout(from:)` sends only `.fit` URLs
  through the scanner; zero or one session message keeps the direct path, two or
  more open the review sheet. Scanning and importing never run on `@MainActor`.
- Persistence reuses the same `beginBatchImport` → `stageWorkout` →
  `commitBatchImport` sequence as archive import. No second staging format or
  batch token type is introduced.
- `WorkoutImportServicing.importWorkout` still returns exactly one `RunWorkout`.
  Multi-session FIT is an additional service rather than a weakening of the
  general import contract.
