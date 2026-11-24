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
RunPlayStudio → RunPlayPlatform → RunPlayCore → RunPlayEngine
```

```
RunPlayEngine/                 # Pure Swift computational engine (non-product target)
├── Sources/                   # Kernels and their value types (`package` access)
├── TestSupport/               # Test-only parity primitives shared by the engine and Core suites
└── Tests/                     # RunPlayEngineTests (engine unit tests)

RunPlayCore/                   # Platform-neutral Swift facade (no UI frameworks)
├── Sources/
│   ├── Models/                # Data structures (RunWorkout, RoutePoint, etc.)
│   ├── Accessibility/         # Pure spoken summaries and chart accessibility models
│   ├── Importers/             # File format parsers (JSON, GPX, TCX, FIT)
│   ├── Engine/                # Internal adapters over RunPlayEngine (`internal import`)
│   └── Services/              # Analysis, splits, segments, comparison, projection, export
└── Tests/
    └── RunPlayCoreTests/      # Platform-neutral tests (includes engine adapter and golden digest tests)

RunPlayPlatform/               # macOS non-UI layer (MapKit, SceneKit, AppKit values, ImageIO DEM tiles)
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

### Swift engine route and analysis kernels

`RunPlayEngine` is the pure Swift computational engine. It uses only the Swift
standard library and the platform C math module, builds with strict memory
safety, and declares everything with `package` access. It is a non-product
target. Only `RunPlayCore` imports it, with `internal import`, through the
adapters in `RunPlayCore/Sources/Engine`. The package contains no C or C++
target and enables no C++ interoperability.

The engine provides the route input value (`EngineRouteInputSample`) and its
sample ceiling (`EngineRouteLimits.maxRouteInputSamples`), scalar geodesy
primitives (`EngineGeodesy`), and one kernel per production operation:

| Kernel | Engine entry point | One engine call per |
| --- | --- | --- |
| Combined route-quality geometry (stages 2–4) | `EngineRouteQuality.process` | route |
| Per-workout personal heatmap coverage | `PersonalHeatmapCoverage.compute` | workout per adaptive attempt |
| Constrained-DTW path solve for Route-Aware comparison | `RouteAlignmentDtw.solve` | alignment attempt |
| Segment and personal-record window searches | `SegmentDetection.search` | `SegmentDetector` invocation |
| Multi-pass elevation profile build | `EngineElevationProfile.build` | profile build |
| Pace, heart-rate and power route-metric scale and buckets | `RouteMetricScaleBuckets.assign` | profile finalization |
| Heart-rate training load | `TrainingLoadKernel.compute` | training-load pass |
| DEM tile planning | `DemTilePlanning.plan` | correction pass |
| DEM bilinear sampling | `DemElevationSampling.sample` | correction pass |

The engine is a literal translation of the C++23 kernels it replaced: same
constants, same operation order, same limitations. Verification:

- engine unit tests (`RunPlayEngineTests`), on macOS and Linux, and under
  AddressSanitizer on Linux CI;
- one golden digest test per kernel in `RunPlayCoreTests`
  (`*GoldenTests.swift`): one FNV-1a-64 digest per CI platform, derived from
  the C++ kernel before its removal, pins the outputs bit for bit;
- adapter behaviour tests in `RunPlayCoreTests` (`RunPlay*BridgeTests`);
- `EngineCallCardinalityTests`, which enforces one engine call per production
  operation;
- the boundary validator `scripts/validate-swift-engine-boundaries.py` (source
  scan plus SwiftPM target graph).

See [engine.md](engine.md) for the boundary inventory and verification detail.

```text
Core stage-1 ordered [RoutePoint]
    → [EngineRouteInputSample] (built once by the Core adapter)
    + optional [UInt8] selection
    → EngineRouteQuality.process(...) throws(RouteQualityError)
    → EngineRouteQualityResult (one output sample per input sample)
    → Core retained points / diagnostics / provenance
    → Core source-speed validation and elevation
```

Core enumerates points in source order and uses the array offset as
`sourceIndex`; point UUID ownership stays in Core. Timestamp values are
exactly `Date.timeIntervalSinceReferenceDate` with no rounding. Optional values
use `Double?` and never use numeric sentinels. The engine exposes no batch
inspection, status, or digest call.

Boundary ownership is explicit:

- Core owns every input and keeps it alive for the call;
- the engine borrows each input as a `Span` for one synchronous call, retains
  nothing, and performs no callback;
- the engine returns its output by value: an array holding exactly the entries
  it produced, or a result struct. A per-sample kernel returns one entry per
  input sample. No kernel negotiates capacity or asks for a retry;
- a failed call throws the kernel's typed error (one error enum per kernel)
  and returns nothing, so no partial output exists;
- the Core adapter translates engine values to Core models. Engine types
  never appear in a public `RunPlayCore` API.

#### Geodesy primitives

`EngineGeodesy` provides allocation-free primitives equivalent to the Core
`GeoDistance` implementation:

```swift
package struct EngineLocalMeters: Equatable, Sendable {
    package let xMeters: Double
    package let zMeters: Double
}

package enum EngineGeodesy {
    package static let earthRadiusMeters = 6_371_000.0

    package static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool
    package static func distanceMeters(
        latitude1: Double, longitude1: Double, latitude2: Double, longitude2: Double
    ) -> Double
    package static func projectToLocalMeters(
        latitude: Double, longitude: Double, centerLatitude: Double, centerLongitude: Double
    ) -> EngineLocalMeters
}
```

These are a literal translation, not an accuracy redesign. The Earth radius,
Haversine formula, projection coefficients, and operation order are unchanged,
including `degrees * pi / 180` evaluated left to right. There is no longitude
wrapping, ellipsoid, clamping, or third-party geodesic library. Existing
limitations are preserved: the projection does not validate, clamp, or wrap its
inputs and propagates non-finite values, and some exactly antipodal pairs round
the haversine term above 1 so the distance is NaN.

Swift never contracts floating-point expressions, so a multiply and an add are
always two rounded operations. As a literal-translation rule, each multiply and
each add of an accumulation still stays in its own statement where the original
kernel had it so, which keeps every intermediate rounded exactly as before.
Results can differ between macOS and Linux only through the platform math
library; that is why each golden digest is recorded per CI platform.

#### Production combined route-quality geometry

`EngineRouteQuality` exposes one kernel for stages 2–4:

```swift
package enum EngineRouteQuality {
    package static func process(
        _ samples: borrowing Span<EngineRouteInputSample>,
        policy: EngineRouteQualityPolicy,
        distancePolicy: EngineRouteDistancePolicy,
        selection: consuming Span<UInt8>?
    ) throws(RouteQualityError) -> EngineRouteQualityResult
}
```

Route size is bounded in Core, not at the engine boundary.
`WorkoutImportResourceLimits.maxRoutePointCount` (1,000,000) is the product
limit, enforced by every importer and by a preflight in
`RouteQualityProcessor.process` before the engine input array is built.
`EngineRouteLimits.maxRouteInputSamples` (1,250,000) is an internal safety
ceiling 25% above it, so `RouteQualityError.resourceLimit` means a Core-side
limit failed to run rather than that a user's workout is too long.

Semantics:

- output index matches input index;
- isolated coordinate outliers are rejected; adjacent candidates are retained;
- implicit gaps and explicit source segments form contiguous final segments;
- supplied-distance validity resets per final segment;
- coordinate-derived steps reuse internal geodesy helpers;
- no distance is added across explicit or inferred boundaries;
- point identity and order are preserved.

**Core performs route-size validation, basic field sanitization, sorting,
initial source-segment compaction, source-speed validation, elevation,
diagnostics translation, public models, and persistence.**

**The engine performs production outlier evidence, isolated-point rejection,
implicit gap inference, final segment compaction, supplied-distance policy, and
normalized cumulative distances through one engine call.**

`RouteQualityProcessor` reaches the engine only through the route-quality
adapter (`RunPlayCore/Sources/Engine/RunPlayRouteQualityAdapter.swift`). No
scalar per-point engine calls are allowed in production.
`scripts/validate-swift-engine-boundaries.py` enforces that isolation
mechanically.

Timelines, splits, projection services, and file parsers remain in
`RunPlayCore`. Elevation-profile construction runs in the engine (see
[ElevationProfile and WorkoutAnalysisContext](#elevationprofile-and-workoutanalysiscontext)).
Per-workout personal heatmap
route coverage runs in the engine, and cross-workout heatmap aggregation stays
in Core by an explicit profiling-driven decision; see
[Personal Heatmap](#personal-heatmap). The Route-Aware constrained-DTW path
solve runs in the engine, while alignment sample construction, direction
detection, blocks, diagnostics, quality, and aligned metrics remain in Core;
see [WorkoutComparisonService](#workoutcomparisonservice).

`RunPlayCore` remains the only Swift-facing core API and continues to own
app-facing models, `Codable` compatibility, errors/diagnostics, actors,
filesystem persistence, schema migration, and translation between Core models
and engine values.

Each route operation must cross the engine boundary in one call, never one
call per point. Platform and Studio must not import the engine.

Heart-rate training load follows the same contract: one borrowed sample span,
a fixed-size `TrainingLoadSummary` returned by value, and a typed
`TrainingLoadError` on failure. Core retains interval weights (never across
recording gaps or pauses), policy, estimation, cancellation, and persistence.

Kernel boundaries:

- combined route-quality geometry: a borrowed `Span<EngineRouteInputSample>`
  and an optional borrowed `Span<UInt8>` selection. Returns one
  `EngineRouteQualityOutput` per input sample.
- per-workout personal heatmap coverage: a borrowed
  `Span<PersonalHeatmapRouteSample>`. Returns a `PersonalHeatmapCoverageResult`
  whose `cells` array holds exactly the de-duplicated cells the engine found,
  strictly ascending by (y, x). There is no capacity negotiation and no retry.
  Core increments its cross-workout counts dictionary directly from the
  returned cells and creates no per-workout `[PersonalHeatmapCellID]` in
  production.
- constrained-DTW path solving: two borrowed `Span<RouteAlignmentDtwSample>`
  inputs (primary and comparison) in one call. Returns a
  `RouteAlignmentDtwPath` whose `cells` array is the path. A valid path never
  exceeds `primary_sample_count + comparison_sample_count + 1` cells. A failed
  solve throws `RouteAlignmentDtwError` and returns no path.
- segment detection: a borrowed `Span<SegmentDetectionSample>`. Returns a
  `SegmentDetectionResult` with a fixed ten-entry inline candidate array and a
  `candidateCount` (at most ten: the five segment-highlight kinds plus one
  candidate per personal-record window the route covers). Each internal
  distance-window search retains its per-search evaluation bound.
- elevation profile construction: a borrowed
  `Span<EngineElevationProfileInput>`. Returns an
  `EngineElevationProfileResult` with one output sample per input route point.
  The output array is the route-sized workspace; the build makes no other
  route-sized allocation. One engine call occurs per profile build. The engine
  performs source altitude screening, spike and
  short-excursion rejection, supported rejected-sample interpolation, run
  classification, distance-domain smoothing, reliable interval tracking, and
  deadband-confirmed cumulative ascent/descent. Core retains route-point
  UUIDs, public `ElevationProfile`/`ElevationProfileSample` models, all
  distance-query APIs, policy ownership, cancellation, diagnostics, and
  persistence.
- DEM tile planning: a borrowed `Span<DemRouteSample>` of coordinates. Returns
  a `DemTilePlanResult` whose `tiles` array holds exactly the planned
  `DemTileKey` values, strictly ascending by (y, x). It is bounded by the tile
  budget Core passes in the policy: the planner's internal tile set never
  grows past that budget, and a route needing more throws
  `DemTilePlanError.tileBudgetExceeded` (the workout keeps recorded
  elevation). That error is not a retry signal. The listed tiles are exactly
  those holding a bilinear corner with non-zero weight, computed by the same
  internal footprint rule the sampler uses. Pixels hold the height at their
  centre, so a sample within half a pixel of a tile edge also needs the
  neighbouring tile; columns wrap across the antimeridian, rows clamp at the
  Web Mercator limit (±85.0511°) and never wrap across a pole, and invalid or
  polar coordinates need no tile.
- DEM bilinear sampling: a borrowed `Span<DemRouteSample>` of coordinates, a
  borrowed `Span<DemTileKey>` directory of the tiles present, and their
  borrowed `Span<Float>` heights (`tile_size^2` per tile, row-major from
  the north-west pixel, directory order). It borrows three inputs in
  one call and returns a `DemSamplingResult` with one
  `DemElevationOutputSample` per coordinate: an elevation
  and a `DemSampleStatus` (`sampled`, `invalidCoordinate`, `outsideProjection`,
  `missingTile`, or `implausibleHeight`, reported in that precedence). The
  directory contract (order, key range, budget, height count) is validated
  before any output is produced, and a violation throws
  `DemSamplingError.invalidTileDirectory`; a
  missing tile is never an error, only a per-coordinate fallback.
  Interpolation runs between pixel centres over non-zero-weight corners only,
  with each multiply and add in its own statement; heights
  outside the policy's plausible range, or non-finite, mark the coordinate
  implausible. The heights are single precision because every Terrarium height
  — a multiple of 1/256 m within ±32,768 m — is exact in a float.

#### Swift engine policy defaults

The allowed, justification-required, and forbidden constructs for
`RunPlayEngine` are defined once in the root `AGENTS.md`, under "Swift engine
policy (defaults)". This document does not repeat them.

Boundary checks: `python3 scripts/validate-swift-engine-boundaries.py`.
Engine tests: `swift test --filter RunPlayEngineTests`.
External package consumption:
`swift build --package-path Tests/PackageConsumerSmoke`.

The package enables no C++ interoperability: no target sets
`.interoperabilityMode(.Cxx)` or a C++ language standard. Platform and Studio
keep pure Swift public APIs and never import `RunPlayEngine`.

### Commands and accessibility

Menu shortcuts are owned by `CommandRegistry` and `WorkoutViewCommands`, with
focused action bundles (`ReplayActions`, `LibraryActions`, `MapActions`) published
from the active workspace. Pure summary text lives in RunPlayCore so Linux CI can
test spoken semantics without AppKit. See
[accessibility-audit.md](accessibility-audit.md).


### Swift concurrency

Swift 6 strict concurrency is enforced across the package.

- UI state in `AppState` and `ReplayController` is isolated to `@MainActor` and
  currently uses Combine's `ObservableObject` / `@Published` model.
- Workout-library persistence and mutations are serialized through
  `WorkoutLibraryStoreActor` (an `actor` in `RunPlayCore`).
- `WorkoutImportService` is an `actor` in `RunPlayCore`; parsing never runs on
  `@MainActor`.
- Values passed across actor boundaries must conform to `Sendable`; preserve
  the explicit conformances on the relevant `RunPlayCore` models.

Rules:

- Do not add `@unchecked Sendable` merely to suppress a concurrency error.
  Prefer checked conformance; when unchecked conformance is unavoidable for a
  lock-protected or otherwise externally synchronized type, document and test
  the invariant.
- Never mutate `@MainActor` state from a background task directly. Use `await
  MainActor.run { }` or `@MainActor` method dispatch.
- Do not introduce `DispatchQueue` or `OperationQueue` — use Swift structured
  concurrency (`async`/`await`, `Task`, `actor`) exclusively.
- `RunPlayCore` must not import Combine. `RunPlayPlatform` may use Combine for
  non-UI observable controllers only.

View models currently use Combine observation:

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var workouts: [RunWorkout] = []
    @Published var selectedWorkout: RunWorkout?
    // ...
}
```

Match the live source when changing observation rather than migrating the
architecture incidentally.

`FileAppSessionStore` is an actor that performs the session JSON I/O off the
main actor. For what the snapshot holds and when `AppSessionController` applies
and writes it, see
[Application scene and session restoration](#application-scene-and-session-restoration).

Data crosses the layers in one direction, and every hop is an `await`:

```
WorkoutLibraryStoreActor (actor, RunPlayCore)
    ↓ await
AppState (@MainActor, RunPlayStudio)
    ↓ @Published property
SwiftUI View (implicit MainActor)
```

Never skip a layer or call across this chain without `await`.

### UI layer (RunPlayStudio)

`RunPlayStudio` owns all SwiftUI, Swift Charts, app lifecycle, and `@MainActor`
UI state. Neither `RunPlayPlatform` nor `RunPlayCore` imports it.

| Type | Role |
|------|------|
| `AppState` | Central `@MainActor ObservableObject` coordinator. Owns `workouts`, `selectedWorkout`, `workspaceMode`, favourites, `replayController`, comparison state, `personalHeatmap`, `workoutLibrary`, and library operation state. |
| `AppWorkspaceMode` | Mutually exclusive top-level destinations; the cases are listed in [Workspace navigation](#workspace-navigation). |
| `WorkoutLibraryViewModel` | All Runs search/filter/sort/tag state, smart-collection query context, multi-select, search documents, cancellable off-main queries, stale-result suppression. |
| `WorkoutLibraryView` | All Runs table UI (Tags column), filters, tag/collection sheets, Modified/Revert/Update chrome, empty states, metadata editor. |
| `WorkoutTagViews.swift` | Tag chips, single/bulk tag editors, Manage Tags, Save/Manage Smart Collections. |
| `PersonalHeatmapViewModel` | Dedicated heatmap filters, background aggregation, stale-request suppression, and in-memory cache. |
| `PersonalHeatmapView` | Heatmap workspace UI: filters, statistics, map areas, legend, empty/loading/error states. |
| `ReplayController` | `@MainActor ObservableObject` wrapper around `PlaybackEngine`. Drives timeline, playback speed, and current route point. |
| `ContentView` | Injected root view. Hosts the sidebar and detail split, owns the `.fileImporter` modifier, and delegates import/session lifecycle to app-owned state. |
| `FITSessionImportSession` | `@MainActor ObservableObject` for one multi-session FIT import: security-scoped URL, scan result, selection, phase, progress, report. Holds descriptors only — never decoded FIT messages. |
| `FITSessionImportView` | Import FIT Sessions review / progress / report sheet. Mirrors `StravaArchiveImportView` so keyboard, modal blocking, and dismissal behave identically. |
| `WorkoutDetailView` | Detail host. Provides shared replay controls, metrics panel, and tab picker (Overview / Charts / Splits / Segments). |
| `OverviewView` | Default landing tab. Embeds `MapReferenceView` / `RouteMapCanvas` and passes the current point index from `ReplayController`. |
| `WorkoutRouteMapViewModel` | Single-workout metric route lines: off-main builds, cache, cancellation; does not rebuild on replay ticks. |
| `RouteMapCanvas` | Shared SwiftUI `Map` surface for single-run, comparison, and heatmap maps. Owns `MapCameraPosition`, optional `RouteMapArea` fills, and the 2D/3D pitch toggle. |
| `RouteMetricLegendView` | Focused numeric/no-data/accessibility legend for workout-relative route coloring. |
| `MetricsChartView` | Pace, elevation, HR, speed charts. Drag-to-seek pauses playback and updates `ReplayController`. |
| `CompareView` | Comparison host. Shows the comparison held in `AppState` (`comparisonWorkout`, `comparisonPair`), whose `WorkoutComparisonService` builds the results; Route-Aware alignment state comes from `AppState.comparisonViewModel` (`ComparisonViewModel`). |

- `RunPlayStudioApp` holds `AppState` and `AppSessionController` as
  `@StateObject`; `ContentView` and dependent views use `@ObservedObject` for
  app state and replay state. Scene ownership and the session snapshot are
  described in
  [Application scene and session restoration](#application-scene-and-session-restoration).
- Chart drag-to-seek: `WorkoutDetailView` pauses `ReplayController`, then calls
  `seekToDistance(_:)` with the distance emitted by `MetricsChartView`.
- `RouteMapCanvas` is the only map type (see [RouteMapCanvas](#routemapcanvas));
  do not create a second one. Heatmap uses filled `MapPolygon`
  areas under routes; heat intensity must not reuse primary-blue vs
  comparison-orange semantics. Route metric coloring applies only to the
  single-workout map; comparison stays blue/orange.
- Heatmap aggregation runs off the main actor via `PersonalHeatmapViewModel`
  and must not set global `LibraryOperationState` busy for the whole app.
- PNG export follows [PNG Summary Export](#png-summary-export). It renders the
  concrete `ExportSummaryCardView`, never at `NSScreen` scale, and never
  screenshots `RouteMapCanvas` or requires Screen Recording. The export sheet
  and `PNGSummaryExportViewModel` own configuration, preview, and cancellation;
  keep that workflow out of `AppState`.
- FIT import routing through `AppState.importWorkout(from:)` is described in
  [Multi-session FIT import](#multi-session-fit-import).
- Batch review sheets own their own progress. `LibraryOperationState`
  `.importingArchive` and `.importingFITSessions` deliberately do **not** disable
  the main window; `.scanningFITFile` does. `.scanningArchive` disables it
  unless the Apple Health sheet owns the scan (`AppState.appleHealthScan` is
  set), because that sheet shows the progress and can cancel.
- `AppState.isModalPresentationActive` is the app-owned half of modal command
  blocking; `ContentView` combines it with its view-local presentations.

Where a concern belongs:

| Concern | Layer |
|---------|-------|
| SwiftUI views and modifiers | RunPlayStudio |
| `@MainActor` state, Combine publishers | RunPlayStudio |
| PNG summary export | Split across layers; see [PNG Summary Export](#png-summary-export) |
| Distance/pace calculations | RunPlayCore |
| Route projection, segment detection | RunPlayCore |
| Workout library file I/O, manifest, persistence | RunPlayCore |
| Logical application-session file I/O and restoration | RunPlayStudio |

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
| **RunPlayEngine** | Per-workout coverage kernel: Web Mercator projection, grid-cell quantization, effective-segment gap breaking, Amanatides–Woo supercover traversal, per-workout de-duplication, deterministic cell ordering |
| **RunPlayCore** | `PersonalHeatmap*` models, the heatmap coverage adapter (`RunPlayPersonalHeatmapCoverageAdapter.swift`), `PersonalHeatmapBuilder` date filtering, adaptive resolution, cross-workout aggregation, and snapshot finalization. The adapter increments the Core counts dictionary directly from the cell array the engine returns, without a production per-workout `[PersonalHeatmapCellID]`. `PersonalHeatmapProjection` / `PersonalHeatmapGridTraversal` remain as the public Swift reference implementation |
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

Cross-workout aggregation stays in Core. The builder reserves its counts
dictionary with a bounded adaptive hint. For each workout the engine returns
exactly the cells it found, and the adapter increments the dictionary directly
from that array. The engine cell type never leaves the adapter, and the
production path creates no per-workout `[PersonalHeatmapCellID]`. The
array-returning adapter call remains available for parity and adapter tests.

`PersonalHeatmapCellID` mixes both signed X/Y coordinates into one 64-bit input
to Swift `Hasher`. That mixed word is neither persisted nor stable external
identity: equality, ordering, geographic meaning, and keyed `Codable` continue
to use the original coordinates. Reservation hints are capped Swift allocation
advice only; they never truncate aggregation or become a product/library limit.

The ownership decision was made by profiling while the coverage kernel was
C++23 (`scripts/run-personal-heatmap-profile.sh`). Its findings at that time:

- the per-workout coverage kernel dominated every production-reachable
  configuration;
- cross-workout counting was the largest remaining Core cost, and that cost was
  Swift `Hasher` work plus dictionary growth rather than algorithmic work;
- sorting and materialization are capped by the rendered-cell budget.

The contract reasons hold for the Swift engine too. A whole-pass engine
aggregation call would require a new arbitrary
whole-library route-point limit — `WorkoutImportResourceLimits` bounds a single
workout, not a library — and would run uninterruptibly across the whole library,
losing per-workout cancellation. A per-workout call would require either a
retained engine accumulator, which contradicts the contract that the engine
retains nothing between calls, or a Core-owned open-addressed table plus a
rehash boundary. Keeping aggregation in Core adds none of those contracts. See [phase-plan.md](phase-plan.md).

#### Remaining-core hotspot profile conclusion

`scripts/run-remaining-core-hotspot-profile.sh` profiles the remaining active
production paths with production-equivalent Mode A/B decomposition, exact
output digests, a 5% accounting-residue gate, and statistical release timings.
Machine-specific milliseconds live only in profile output, not here.

The conclusions below were reached while the kernels were C++23. The kernel
boundaries they selected are unchanged in the Swift engine.

**Completed boundary:** `SegmentDetector` performs its bounded window search
through one engine call per invocation. Segment detection remains a material
analysis phase.

**Completed boundary:** `ElevationProfile` multi-pass construction runs in the
engine. The golden digest and the elevation tests preserve gap, spike,
excursion, smoothing, and deadband gain/loss semantics. SegmentDetector
consumes the Core elevation snapshot after the engine elevation build.

**Completed boundary:** route-metric numeric finalization performs
deterministic distance-weighted lower/median/upper scale construction,
normalization, bucket assignment, coverage accumulation, and numeric summary
construction through one engine call per pace, heart-rate, or power profile.
The engine returns the output samples in source order. Core retains raw metric
extraction,
distance-domain smoothing, localized labels, public profile models,
availability and caching, cancellation, Platform line coalescing, UI state,
diagnostics, and persistence.

**Post-cutover decision:** no further kernel is selected.
MovementProfile remains in Core because its analysis share was too
small to justify another engine boundary.

**Intentional Core ownership:**

- importer decode (Foundation JSON / XMLParser / FIT binary framing);
- `WorkoutLibraryQueryService` over lightweight library entries;
- `RouteAlignmentSampleBuilder` and Core post-DTW block/diagnostics work
  (the DTW path solve runs in the engine);
- route-metric extraction, smoothing, label formatting, public profile
  materialization, and Platform map-line presentation;
- public elevation models, distance queries, and SegmentDetector snapshot
  materialization;
- cancellation, identity, Codable models, and persistence.

**Why other candidates stay in Core:** MovementProfile remains below the threshold
for another engine boundary; importer parsers are not
portable pure-numeric kernels; MetricSmoother alone is too small;
SplitCalculator is modest once context is shared.

Legacy SceneKit projection stays low priority unless it regains a shipped
caller.

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
in Core, deliberately in the same ownership bucket as raw pace/heart-rate
extraction rather than an engine kernel: it runs once per analysis, is never on a
per-view path, and an engine boundary would add a kernel contract for no
user-visible gain.

#### Bucketing, ranges, and gaps

- Each run belongs to exactly one period: the period containing its canonical
  start **local date**. Runs crossing midnight or a week boundary count
  entirely in their start period.
- The local date resolves in the run's recorded UTC offset when the source
  format carried one (GPX/TCX/JSON capture the literal designator, `Z` being
  0); FIT logs UTC instants only, so those runs fall back to the system zone.
  `WorkoutMetadata.recordedUTCOffsetSeconds` carries the value.
- Weeks follow a `WorkoutTrendsWeekConvention` (first weekday and minimum
  days in the first week). Core defaults to ISO 8601 (Monday start; the key
  year is the week-date year); the app passes the user's calendar convention,
  so weeks start on the locale's first weekday or the one chosen in System
  Settings. Months and years share Gregorian boundaries in every convention.
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
pass as segments (one engine detection call produces both) and stored on the
snapshot as `RunWorkout.personalRecords`. The field is decode-tolerant and
**deliberately not gated on `analysisVersion`**: absence (`nil`) is the
backfill marker, while a non-`nil` value with zero windows means the run
attempted no window.

| Layer | Responsibility |
| --- | --- |
| **RunPlayEngine** | The five extra fixed-window fastest searches (1 mile, 5 km, 10 km, half marathon, marathon) inside the existing single segment-detection engine call; canonical window lengths live in engine constants so Core record identity cannot drift |
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
  evaluation). Core's `RouteAnalysisBudget.boundedStep` raises each step to
  at least `distanceSpan / (maxEvals − 1)` before the engine call, so a
  compliant configuration can never exceed the per-search budget: exhaustion
  degrades to a coarser step and a candidate is never silently dropped. The
  engine's `SegmentDetectionError.resourceLimit` pre-check remains a
  contract-violation safety net.
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

### Heart-rate training load

Per-workout training load is a stored analysis product; the fitness/fatigue
rollup over the library is derived and never persisted.

| Layer | Responsibility |
| --- | --- |
| **RunPlayEngine** | One summary-only engine call per measured pass: interval-weighted Banister TRIMP, five-zone seconds, and coverage aggregates |
| **RunPlayCore** | `AthleteProfile` (optional birth year, resting/max HR, custom zone bounds, coefficient set) with `FileAthleteProfileStore` at `<library-root>/athlete-profile.json`; `EffectiveTrainingLoadProfile` derivation (measured max wins, else Tanaka `208 − 0.7 × age`, else population default — always disclosed); `TrainingLoadCalculator` interval construction and measured-vs-estimated policy; `TrainingLoadSnapshot` on `RunWorkout.trainingLoad`; the resumable store-actor backfill; `TrainingLoadRollup` daily aggregation and the CTL/ATL/TSB recursion; `TrainingLoadChartAccessibilitySummary` spoken disclosures |
| **RunPlayPlatform** | None |
| **RunPlayStudio** | `TrendsViewModel` training-load compute stage (scope-resolution reuse, range-anchored day slicing, revision-keyed cache with a per-snapshot training-load digest), `TrendsView` training-load panel with daily bars + fitness/fatigue/form lines, model preference controls, inline backfill banner, and `AppState` orchestration (profile ownership, import re-stamp, one-pass backfill trigger on first Trends open) |

Semantics:

- **Interval weights are active-time semantics.** The calculator builds one
  interval per adjacent same-segment point pair; an interval's rate is the
  mean of its endpoints when both are valid (30–230 bpm), and recording gaps
  or pauses spanning a segment boundary contribute no weight at all.
- **Measured requires real coverage.** Valid heart-rate time must reach both
  300 seconds and half the covered active time; otherwise the load is an
  estimate. Zone seconds and mean rate exist only on measured loads.
- **Estimates are labelled, conservative, and never silent.** The estimator
  maps average pace onto an assumed heart-rate reserve banded from 0.30 to a
  0.75 cap (duration-only floor 0.50 when pace is unusable); the assumed
  reserve and basis are stored on the snapshot. The bands deliberately
  understate hard strapless efforts rather than inflating load.
- **`analysisVersion` is unchanged.** `trainingLoad` follows the records
  pattern: absence is the backfill marker, and a present snapshot whose
  stored `profile` differs from the current `AthleteProfile` is the stale
  marker. One rule covers both, drives the same resumable
  `WorkoutLibraryStoreActor.backfillTrainingLoad` pass (yields between
  workouts, cancellation keeps completed snapshots and never counts as a
  failure), and leaves `loadLibrary` untouched. Importers and load-time
  migration analyze with the default profile; those snapshots are stale by
  exactly this rule whenever the user configures a profile.
- **The profile is local-only.** It is the only Core-owned persistence
  besides the library store, and a corrupt file falls back to the default
  profile rather than blocking anything.
- **The rollup is daily scalar Swift work.** `TrainingLoadRollup` aggregates
  per-day measured and estimated loads (a day with runs but only estimated
  loads is flagged `noHRData` — zero-contribution, never a rest day), fills
  the contiguous span with rest days, and runs the standard first-order
  recursion `state_d = state_{d−1} + (load_d − state_{d−1})/τ` for fitness
  (default 42 days) and fatigue (default 7); form is the same-day
  difference. Estimated loads are excluded from the model unless explicitly
  opted in, and HR coverage over the window is disclosed in captions,
  hover, and spoken summaries. The Trends panel charts daily load bars
  (estimated days visually distinct and never merged into the model) plus
  the three lines; time constants and the opt-in are presentation
  preferences and never touch stored snapshots.
- **Trends invalidation follows the library-level revision discipline.** The
  backfill bumps no revision per workout; the pass-end `refreshTrends`
  recomputes once, and the Trends request key carries a per-snapshot
  training-load digest so the cache cannot serve a pre-backfill result.
  Import re-stamping happens before the in-memory library update, so the
  normal revision hash (which includes each workout's training load) covers
  it.

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
   same one-kernel-call `RunPlayRouteAlignmentDtwAdapter` solve used by
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
workouts pending. Because the pass suspends while matching representatives,
it merges its route-group result into a re-read manifest snapshot before
that single write: deletes and manual decisions committed inside the
window (rename, re-pin, merge, deliberate removal — never auto re-added)
win over the pass's stale copies, groups written by another overlapping
pass survive the last write, a group removed inside the window is not
resurrected — a workout the pass matched into it falls back to the
backlog for the next pass — references to workouts that left the
library or their group are repaired, and groups left empty are dropped.
The route-groups library revision bumps once per pass, never per workout;
per-item progress lives in the Routes view model. Deletion repairs
membership transactionally in the store actor.

**Naming.** No geocoding — the privacy model forbids it. Unnamed groups
derive a descriptive default from the representative's own geometry
("5.2 km Loop" versus "10.1 km Route" by start-to-finish closure); users
can rename at any time. Because `%.1f km` rounding widens name collisions
(1.16 km and 1.24 km both render "1.2 km"), surfaces that list groups
derive names for the whole set at once through
`WorkoutRouteGroup.derivedDisplayNames(for:loopClosureDistanceMeters:)`:
a colliding base name gains an eight-point compass token — the bearing
from the representative's start point to the centre of its bounding box,
never start-to-finish, which for a loop is numerical noise — refined to a
sixteen-point sector, then to a stable digest of the group id ("1.2 km
Loop (NE·7f3)"), each group at the shortest of 3, 6, 8 hex digits that
no sibling shares — the abbreviated-object-name rule, as with short git
object names — until the names differ. A collision is a shared *rendered
name*, not a shared sector: every member of a set of groups that emit the
same string escalates together, to a fixpoint. That matters because a
sixteen-point sector can straddle an eight-point boundary (NNE spans the
N/NE boundary at 22.5°), so two groups from different coarse sectors can
render the same fine-tier name; comparing buckets instead of strings let
them share it. Every discriminator is intrinsic
to the group (persisted facts or the persisted id): no rank, count, or
sort order participates, so importing another colliding group — bulk
historical imports included — never renames groups already named; a
discriminator lengthens only for the groups that share its prefix, so an
arrival cannot change a name it does not collide with, and names revert
when the collision goes away. (Read-time derivation follows the current
representative, so a re-pick would move a derived base name and token; the
store prevents that by materializing names — see below.) User-assigned names are returned
verbatim and never participate in disambiguating others, and the
derivation is a pure function of the input set — input order decides
nothing. The loop-closure threshold
(`defaultLoopClosureDistanceMeters`, 100 m) lives on `WorkoutRouteGroup`,
the single product copy of the number.

Derived names are **materialized**, not recomputed on every read. A group
carries two fields: `name` (user-assigned) and `derivedName` (automatic);
display is `name ?? derivedName ?? fallback`. Manifest repair — which runs
before every save — fills `derivedName` for any group that has a
representative summary but no stored name, so a group is named once, when
it is first persisted, as a set lookup against every name already stored:
a newcomer that collides refines to the first free rung of its own ladder
(bare, eight-point, sixteen-point, id digest) and the name already shown
stays put. Stored names are then frozen — a representative change (a user
pin, or the quality rule re-picking when a joiner outranks the current
representative) moves neither the base name nor the compass token; the
trade-off is that a stored name describes the representative the group had
when it was first saved, and only a rename changes it — and renaming is non-destructive: clearing a rename returns
the stored original. User-named groups get a derived name too, chosen
after the unnamed ones so it collides with nothing. A manifest that
predates the field is migrated on its first load, whole set at once, and
persists exactly the names its surfaces were already showing. Both fields
are additive optionals, so the schema stays at v4.

Manual controls: rename, merge two routes, remove a run from a route
(evaluated-nil marker), and pin a representative. A full re-cluster action
replays the greedy rule chronologically with progress and cancellation,
replaces the manifest in one atomic write (cancelled or failed passes leave
the previous groups untouched), and carries over user names, derived names,
and pins whose referenced workouts still cluster together. When several
previous groups' reference workouts land in one new group, the previous
group contributing the most members to it wins, then the one whose
contributed members start earliest; the others' names are dropped.

The All Runs query filter and the Personal Heatmap filter row both gain a
"route" restriction; the filter evaluates `WorkoutLibraryEntry.routeGroupID`
through the ordinary query service and is saved-query compatible. Each
route entry in both menus carries a secondary line with its run count and
month span ("5 runs · Mar – Aug 2026"), derived on the fly from library
entries by `RouteGroupMenuDetail` — the same `routeGroupID` membership the
filter evaluates — and never persisted. Routes
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
construct a second production coordinator. `RunPlayStudioEntryPoint` is the
process entry point and launches `RunPlayStudioApp`. In debug builds only, it
first routes a `--demo-assets` launch to the headless README media generator
([demo-assets.md](demo-assets.md)). That mode never constructs `AppState` or
opens a window. Closing and reopening the main
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

### Route metric coloring

Single-workout Apple Maps routes can be colored by Solid, Pace, Heart Rate, or
Corrected Elevation. `RouteMetricProfileBuilder` (Core) is the only source of
interval metrics, distance-weighted relative scales, and palette-independent
buckets. `RouteMetricMapLineBuilder` (Platform) coalesces buckets into a bounded
set of `RouteMapLine`s. Studio’s `WorkoutRouteMapViewModel` caches results off
the main actor and does not rebuild on replay ticks. Its initial availability
probe returns reusable metric profiles, so the selected metric is not built
twice; only lightweight availability remains cached for later mode switches.

For every non-solid profile, Core performs raw metric extraction and
distance-domain smoothing. Pace, heart-rate, and power then make exactly one
`RouteMetricScaleBuckets.assign` call over a borrowed sample span. The engine
groups the eligible weighted samples by sort key, constructs the deterministic
numeric scale, normalizes values, assigns buckets, and returns the output
samples and coverage/count summaries by value. Equal sort keys keep source
order, so an equal-weight `+0`/`-0` metric tie has one result on every
platform. This is the one decided difference from the C++23 kernel the engine
replaced, whose result for that tie depended on the standard library.
Corrected elevation intentionally finalizes scale and buckets
in Core (`RouteMetricScaleBucketSwiftFinalizer`) because a same-machine
production A/B showed a kernel regression above the hard gate; that is
mode-owned ownership, not an error-driven fallback. Policy `bucketCount` and
output `bucketIndex` use `Int64` so the public Swift `Int` domain is
preserved. Valid intervals may carry positive-infinite weights (coverage may
be `+infinity`); only finite positive weights contribute to weighted quantiles.
When a scale is known to be impossible after the read-only validation pass,
the engine returns the output in source order and performs no sort. Core then
creates localized labels and
public intervals in source order. Solid mode makes no engine call. Platform
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

Every importer passes its output through `RoutePointSanitizer` before any
analysis or persistence.

Untrusted files are read defensively:

- Every `XMLParser` over a user-supplied file sets
  `shouldResolveExternalEntities = false`.
- An entry point that reads a local file checks `url.isFileURL` before any
  `Data(contentsOf:)`, path-based `FileManager` call or `Archive(url:)` open.
  `FileManager.fileExists(atPath: url.path)` alone does not stop a non-file URL.
- `CSVRow.escape` prefixes `'` to a non-numeric field whose first
  non-whitespace character is `=`, `+`, `-` or `@`. Leading tabs and carriage
  returns go through the whitespace-trimming slow path; never add whitespace
  to `dangerousPrefixes`, which would escape ordinary fields such as `\tHello`.

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
running activities from Garmin FIT SDK Profile 21.205.0. Developer data
fields are decoded: `field_description` (206) and `developer_data_id` (207)
messages are parsed with their official profile layouts, record developer
payloads are captured raw and resolved after parse against the file-wide
description table (so out-of-order descriptions resolve identically), and
recognition is name-based with the application identity retained as
provenance. Recognized running power and running dynamics map onto
`RoutePoint` fields; unrecognised fields persist as metadata plus statistics
(`WorkoutDeveloperFieldSummary`); component accumulation stays out of scope
with accumulating fields decoded as instantaneous samples. Native record
running dynamics (fields 39/41/83/84/85) and native power (field 7) also
decode, under the same per-metric precedence — a developer value wins and
the native field fills what the developer path left absent — with the
summary recording which source supplied each. Other unsupported
FIT profile features remain skipped rather than interpreted.
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

A point's source altitude is its DEM elevation when it has one and its
recorded altitude otherwise; the switch between the two breaks the altitude run
the way a route-segment boundary does. `DEMElevationCorrector` writes the DEM
elevation and decides precedence per point: recorded barometric altitude
outranks DEM, DEM outranks any other recorded altitude and fills missing
altitude, and a point no present tile covers keeps its recorded altitude.

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

Hot-path conventions for route-sized work (importers, analysis, map and export
preparation):

- Accumulate in one inline `for` loop rather than chaining `map`, `compactMap`,
  `filter`, `reduce` or `+` over a route array; each chained step allocates a
  throwaway O(n) buffer or pays a closure call per element. When several
  arrays derive from one source, build them in the same loop with
  `reserveCapacity`. Find the first or last non-nil value with `for case let`,
  not `compactMap { $0 }.first`.
- Precompute a reduction that depends only on immutable construction inputs
  (for example `FITDefinitionMessage.totalDataSize`) once in `init`.
- Cache `DateFormatter` and `ISO8601DateFormatter` as `static let`, never one
  per parse, cell or render. `DateFormatter` is `Sendable` under Swift 6.3 on
  Darwin and Linux; `ISO8601DateFormatter` still needs `nonisolated(unsafe)`.
  `Date.formatted(date:time:)` is slower than a cached formatter and has no
  `.medium` date style, so it is not a drop-in replacement on model paths.
  Measure before replacing a cached formatter, and test the style against a
  reference `DateFormatter` in a non-English locale.

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

The path solve runs in the pure Swift engine. The split is:

| Layer | Responsibility |
| --- | --- |
| **RunPlayEngine** | Bounded band-packed constrained-DTW path solve: band radius, unmatched prefix/suffix expansion, packed row layout, band-cell budget validation, geometry-only point cost, open-beginning seeding, constrained transitions with fixed diagonal → primary-only → comparison-only tie priority, consecutive-warp capping, open-suffix endpoint selection, deterministic path reconstruction |
| **RunPlayCore** | `RouteAlignmentSampleBuilder` compact alignment samples, route-direction detection, `RunPlayRouteAlignmentDtwAdapter` conversion and path validation, alignment blocks and anchors, diagnostics and quality classification, public alignment models |
| **RunPlayStudio** | `ComparisonViewModel` cache, task lifecycle, request-generation stale-result suppression, Compare/Map/Chart UI |

Bounds and boundary semantics:

- at most **2,000 samples per route** (`RouteAlignmentPolicy.maximumSamplesPerRoute`)
  and at most **4,000,000 band cells** (`maximumBandCells`), the latter checked
  as an estimate before allocation and exactly after the packed layout is built;
- **one kernel call per alignment attempt**; neither the aligner nor the grouping
  matcher calls a kernel per row or cell;
- input spans are borrowed synchronously and the kernel returns an owned path
  only on success;
- cancellation is checked before and after the kernel call and during conversion
  and output translation, not inside the solve;
- `resourceLimit` surfaces as `.unavailable(.resourceLimit)` and `noPath` as
  `.unavailable(.routesTooFarApart)`; contract violations surface as
  `.unavailable(.algorithmFailure)`.

Whole-workout summary cards, kilometre splits, and recorded laps remain
independent of alignment mode.

Replay remains on elapsed time, so its total duration equals summary elapsed
time. Inside a route gap the clock advances while the marker, distance, point
metrics, and active time remain at the stop endpoint. The resume point appears
only at its exact timestamp; no pause coordinates are synthesized.

### RouteMapCanvas

`RouteMapCanvas` is the shared SwiftUI MapKit surface for single-run,
comparison, and personal-heatmap maps. It owns a `MapCameraPosition`, draws `MapPolyline` and
`Annotation` content, and exposes one 2D/3D camera toggle plus native MapKit
zoom controls. The 2D/3D state changes the same map camera:

- one realistic-elevation map style in both modes
- `MapCamera.pitch` of 0° versus a pitched perspective

`RouteMapContent` filters invalid coordinates, computes fitting bounds, and
interpolates selected-distance markers without introducing another renderer.

## Dependencies

### Apple Frameworks Used (macOS targets only)

- **SwiftUI**: App UI and views
- **ImageIO**: Terrarium DEM tile decoding (Platform), and PNG summary export (Studio)
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
- **RunPlayPlatform** owns ZIP access via the exact-pinned ZIPFoundation
  0.9.20 SwiftPM dependency,
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


## Optional watch-folder import

Watch-folder import is **opt-in**: no folder is scanned until the user adds
one in Settings → Watch Folders (or the File → Watch Folders… menu item). It
reuses the existing single-file import pipeline end-to-end and adds no engine
kernel — no `RunPlayEngine` surface, and nothing in the
`RunPlayStudio → RunPlayPlatform → RunPlayCore` dependency direction is
reversed.

- **RunPlayCore** owns the platform-neutral pieces so the ledger and settle
  logic test on Linux with a temporary directory:
  * `WatchFolderConfiguration` (a folder's `UUID` identity, display name,
    **opaque** security-scoped bookmark bytes, optional default tag name, and
    paused flag), `WatchFolderState` (per-folder ledger plus the pending-FIT-review
    queue keyed by content hash), `WatchFolderLedgerEntry`,
    `WatchFolderImportRecord`, `WatchFolderPendingReviewEntry`, and the
    `WatchFolderScanPolicy` tunables.
  * `FileWatchFolderStore` persists a versioned envelope to
    `watch-folders.json` beside the library manifest and athlete profile, with
    atomic writes and tolerant load: a missing, undecodable, or newer-version
    file loads empty rather than throwing or wedging the library. Bookmark
    bytes are stored but never interpreted in Core. The envelope also stores
    master pause independently of each folder's paused flag. Older envelopes
    without it start with master pause off and retain each folder's choice.
  * `WatchFolderScanner` is the pure, clock-injectable decision layer: it
    lists non-recursive eligible files (skipping hidden files, directories, and
    unsupported extensions), classifies them against a folder state and a
    caller-supplied content-hash map (candidates / duplicates / pending review /
    unreadable), tracks the **two-probe size+mtime settle** through
    `SettleTracker`, and performs the bounded content read + SHA-256 hash via
    `ContentDigesting`. `isDirectoryListable(_:)` distinguishes "watched folder
    is gone right now" from "watched folder is empty", which zero files alone
    cannot tell apart. It re-throws the product resource-limit error for an
    oversized file so the failure is definitive rather than retried, and that
    error names the limit actually enforced rather than a second copy of the
    product number.
- **RunPlayPlatform** owns the macOS-only filesystem access:
  * `SecurityScopedBookmarkStore` creates and **stale-tolerantly** resolves
    security-scoped bookmarks and hands back a `ScopedAccess` handle that holds
    the folder's security scope for the whole watch lifetime (released on
    deinit). These APIs are functional no-ops in the current unsigned build but
    become load-bearing unchanged when App Sandbox entitlements land; enabling
    the sandbox is a deliberate follow-up, not part of this feature.
  * `DirectoryWatching` / `DispatchSourceDirectoryWatcher` deliver coalesced
    directory `.write` events as an **advisory early wake**. The coordinator's
    periodic poll stays authoritative, so missed events only add poll latency
    and never lose a file.
- **RunPlayStudio** owns orchestration and every user-facing surface:
  * `WatchFolderCoordinator` (`@MainActor`, `ObservableObject`) is the state
    machine. It resolves bookmarks, holds scoped access, registers watchers,
    runs the authoritative poll plus early-wake scans, drives settle, computes
    content hashes off the main actor in a detached task, applies dedupe,
    records outcomes, and persists state. Scan/settle tracker state is passed
    across the detached-task boundary explicitly so it survives between passes.
    It publishes `recentImports`, `folders`, `isPaused`,
    `pendingReviewBanner`, and `unavailableFolderIDs`.
  * **Unavailability is a first-class state, never silence.** An ejected volume
    or deleted folder is reported once per available ⇄ unavailable edge (never
    per poll) as a readable failure row, the Settings pane marks the folder
    **Unavailable**, and watching resumes automatically when the directory
    returns — the poll loop retries folders that never activated, so a volume
    mounted after launch recovers without a restart. A paused folder is never
    reported unavailable, because pausing stops access on purpose.
  * **Pending-review state is durable and never stranded.** The queued FIT file
    persists per folder, so its banner is restored on relaunch; resolving or
    removing one folder's review re-surfaces another folder's queued review
    instead of dropping it. Entries whose file vanished are pruned rather than
    surfaced, so the banner always offers a review that can actually be opened.
  * **Recovery is folder state, not a file result.** A folder becoming
    available again clears its badge but adds no Recent Imports row, because a
    row there would falsely imply a workout was imported.
  * `AppState+WatchFolderImport` bridges into the existing pipeline: it
    re-stamps training load, adds the workout through the store, refreshes the
    library, applies the per-folder default tag through the existing tag APIs,
    and returns a structured outcome with display detail. It deliberately never
    sets `operationState`, `errorMessage`, or `showingError`, so a background
    import cannot raise a modal alert over whatever the user is doing. The
    three parse-level failure messages live in one shared helper
    (`AppState.parseLevelImportErrorMessage`) consumed by both entry points so
    they cannot drift; only `.unsupportedFormat` and `.fileNotFound` are worded
    per caller, because "the selected file" and "import a file instead" are
    both wrong for a file that arrived by itself.
  * A multi-session `.fit` file is **queued** for the existing FIT review sheet
    behind a non-modal banner and is not ledgered until the user resolves it;
    single-session files take the direct path.
  * Results surface in a toolbar **Recent Imports** popover (per-file
    success/skip/error with reveal-in-Finder) and a Settings pane; there is no
    alert spam and no window blocking.
  * **Speech is aggregated once per scan pass**, never per file and never per
    idle poll. Because the results are non-modal, a VoiceOver user has no other
    signal that a background import finished, so the coordinator emits at most
    a few concise `AccessibilityAnnouncementEvent`s through `AppState`'s
    retained policy: failure outranks success (an error must never be masked by
    a sibling import), unavailability is spoken once per transition, and a
    queued FIT review is announced once rather than re-announced on every poll
    while it waits.
- **Dedupe identity is content, not filename.** Every processed outcome —
  imported, skipped-duplicate, and failed — is ledgered, so a failed file is
  never retried on every scan and a renamed or copied file with identical bytes
  is recognized as a duplicate. Steady-state duplicates are silent; a skip row
  appears only when the same content shows up under a new filename.
- **A file too large to read has no hash, so it cannot be ledgered.** It is
  instead suppressed by an in-memory size/mtime/path fingerprint, which is
  sufficient: the point is to stop re-reading >100 MB from disk on every poll
  and to stop repeating the row, not to survive relaunch.

## DEM elevation correction

DEM correction samples terrain heights from a folder of Terrarium PNG tiles the
user downloaded (see [dem-tiles.md](dem-tiles.md)). It adds two engine calls
and no network access; nothing in the dependency direction is reversed.

- **RunPlayEngine** (the pure Swift engine) plans and samples, never reading
  files or images. `DemTilePlanning.plan` lists the bounded set of XYZ tiles a
  route's bilinear footprints read (columns wrap across the antimeridian, rows
  clamp at the Web Mercator limit), and `DemElevationSampling.sample`
  interpolates Core-supplied decoded
  heights at every route point with a per-point status (sampled, invalid
  coordinate, outside the projection, missing tile, implausible height). Both
  share one pixel-footprint function, so the sampler only ever reads planned
  tiles; a property test over seeded routes, including antimeridian and tile
  corners, pins that.
- **RunPlayCore** decides everything that is policy.
  The DEM elevation adapter (`RunPlayDemElevationAdapter.swift`) converts
  coordinates once, calls the planner,
  hands the planned keys to a `DEMTileSource` (a Core closure between the two
  engine calls; the engine never calls back), packs the heights into one
  array, and calls the sampler. `DEMElevationCorrector` applies precedence per point
  (barometric recorded altitude kept, DEM replacing any other recorded altitude
  and filling missing points, recorded altitude where no tile covers), writes
  `RoutePoint.demAltitudeMeters`, reanalyzes elevation through
  `WorkoutAnalyzer.reanalyzeAfterElevationChange` (route quality is not rerun;
  training load is kept), and stores `DEMElevationCorrection`. The elevation
  profile adapter reads a point's DEM elevation in place of its recorded altitude and
  starts a new continuity group wherever the source switches, so the offset
  between sources never becomes ascent, descent, or a climb highlight.
  `FileDEMTileSettingsStore` keeps the chosen folder in `dem-tiles.json`, the
  store actor runs the resumable library pass and the per-workout re-correct
  and opt-out, and `DEMImportElevationCorrection` corrects new imports without
  ever failing them. `ElevationSourceSummary` words the source for the chart,
  its note, the import summaries, and VoiceOver.
- **RunPlayPlatform** reads the folder: `TerrariumTileDirectory` decodes
  8-bit RGB(A) PNGs with ImageIO straight from the stored pixel bytes (never
  drawn, so no colour management), rejects buffered and malformed tiles as
  unreadable, and keeps a 64 MiB least-recently-used cache of decoded tiles.
  `DEMTileFolderAccess` scans a chosen folder, bookmarks it with the watch
  folders' stale-tolerant `SecurityScopedBookmarkStore`, and reopens it. The
  Strava archive importer takes the same import correction.
- **RunPlayStudio** owns the Settings → Elevation pane, the import hooks and
  their coverage reporting, the Workout menu's Correct Elevation and Use
  Recorded Elevation, the elevation chart's break and dashed fallback at a
  source switch, and `applyElevationChanges`, which refreshes every view that
  shows elevation once per change. The analysis-context, route-map, and Trends
  caches key on elevation too, because a correction changes heights without
  changing any point identifier.
