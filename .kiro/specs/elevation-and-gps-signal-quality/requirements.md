# Requirements Document

## Introduction

RunPlay Studio must normalize valid-but-obviously-wrong GPS coordinates and
noisy altitude before those signals affect route geometry or analysis. The
solution must be deterministic, platform-neutral, local-only, conservative,
and shared by every downstream consumer. Source altitude and the original
imported file remain unmodified.

## Requirements

### Requirement 1: Establish one route-quality pipeline and policy

**User Story:** As a runner, I want every import format and analysis surface to
apply the same quality rules so that results do not depend on which screen I
open.

#### Acceptance Criteria

1. A `RunPlayCore` route-quality processor SHALL perform basic validation,
   isolated coordinate detection, implicit-gap detection, distance
   normalization, altitude sanitization, distance-domain smoothing,
   thresholded gain/loss calculation, and diagnostics in a documented order.
2. Every configurable threshold SHALL live in one `RouteQualityPolicy`; an
   importer, analyzer, chart, exporter, or renderer SHALL NOT define a competing
   quality threshold.
3. Processing SHALL be deterministic, platform-neutral, local-only, and SHALL
   NOT call routing, map matching, geocoding, network elevation, telemetry,
   cloud, or AI services.
4. Ambiguous signal SHALL fall back to retained valid-coordinate behavior rather
   than deleting a route or fabricating data.
5. The pipeline SHALL NOT alter heart rate, cadence, or the original imported
   file.

### Requirement 2: Reject only strongly supported coordinate and speed errors

**User Story:** As a runner, I want obvious GPS teleports removed without
losing legitimate sharp turns, sprinting, switchbacks, or irregular endpoints.

#### Acceptance Criteria

1. An isolated interior point SHALL be rejected only when both adjacent legs
   imply excessive speed, the direct neighbour bridge is plausible, and the
   detour exceeds both a minimum excess distance and a distortion ratio.
2. One fast leg, a long timestamp interval, poor horizontal accuracy, or a
   source speed value alone SHALL NOT reject a coordinate.
3. Valid finite horizontal accuracy MAY support rejection only when the
   candidate is poor and its neighbouring trajectory has better accuracy;
   invalid or negative accuracy SHALL be ignored, not invented.
4. Adjacent candidates, first points, last points, sharp turns, out-and-back
   routes, and internally consistent high-speed samples SHALL be retained when
   the required neighbourhood proof is absent.
5. Non-finite, negative, implausible, or grossly geometry-inconsistent source
   speeds SHALL be discarded so normalized distance and time can derive a
   replacement; legitimate sprint values SHALL remain valid.
6. A recorded zero speed SHALL be discarded only when normalized movement
   exceeds the configured stale-zero threshold; a legitimate stationary zero
   SHALL remain valid.
7. A positive source speed above the configured stationary threshold SHALL be
   discarded when normalized geometry is stationary.
8. Retained route-point IDs SHALL remain unchanged.

### Requirement 3: Convert coherent relocation into a route gap

**User Story:** As a runner, I want a resumed GPS cluster to remain visible as a
disconnected route instead of adding an invented journey.

#### Acceptance Criteria

1. A large relocation SHALL create an inferred boundary only when speed or
   interval evidence supports discontinuity and a configurable number of
   following points form a coherent cluster.
2. Existing explicit route boundaries SHALL remain authoritative and SHALL NOT
   be duplicated.
3. A long timestamp interval without geographic relocation SHALL NOT introduce
   a boundary.
4. Long-interval evidence SHALL exceed the following cluster's sampling cadence
   by a configurable ratio so uniformly sparse routes remain continuous.
5. A relocated cluster with valid timing SHALL be confirmed by plausible
   time-derived speed; the absolute step limit SHALL be only a missing-timing
   fallback.
6. Inferred segment indexes SHALL be compact and deterministic and SHALL NOT
   create empty segments.
7. Distance, speed, pace, elevation delta, smoothing, interpolation, replay
   movement, and map geometry SHALL NOT cross an inferred or explicit boundary.
8. Introducing an implicit boundary SHALL retain a non-fatal analysis warning.

### Requirement 4: Preserve and record distance-source precedence

**User Story:** As a runner, I want valid device distance preserved even when
GPS geometry is noisy, while incomplete distance falls back safely to retained
coordinates.

#### Acceptance Criteria

1. A complete finite non-negative monotonic supplied distance series SHALL be
   eligible for preservation and SHALL be rebased at compact segment
   boundaries without decreasing.
2. GPX SHALL derive distance from retained coordinates; TCX and JSON SHALL
   preserve only a complete valid supplied series; FIT SHALL decide per segment.
3. Missing or invalid supplied distance SHALL fall back to retained coordinate
   geometry after coordinate cleanup.
4. Neither distance source SHALL add distance across a route gap.
5. The workout SHALL persist overall and per-segment distance provenance so a
   migration does not silently replace a previously established device series.
6. Legacy snapshots without provenance SHALL use a conservative source-aware
   inference policy.

### Requirement 5: Derive one aligned corrected elevation profile

**User Story:** As a runner, I want flat-route noise suppressed while real
climbs, descents, below-sea-level routes, and missing altitude remain truthful.

#### Acceptance Criteria

1. `RoutePoint.altitudeMeters` SHALL retain finite source altitude; corrected
   altitude SHALL live in an aligned derived `ElevationProfile`.
2. The profile SHALL expose corrected altitude, source rejection state,
   cumulative ascent/descent, corrected altitude at cumulative distance, and
   ascent/descent/signed change over a distance range.
3. Non-finite and physically implausible analysis altitude, locally unsupported
   interior or one-sided continuous-run endpoint spikes, and extreme bounded
   two-sample interior excursions SHALL be rejected without removing legitimate
   stairs, steep hills, sustained climbs, descents, switchbacks, or negative
   elevations; horizontal bounds SHALL use travelled normalized distance.
4. A rejected isolated interior source sample MAY be filled only from immediate
   reliable neighbours in the same route segment; rejected run endpoints,
   adjacent rejected samples, and true missing spans SHALL remain gaps.
5. Smoothing SHALL use a centered distance window independently within each
   continuous non-missing route segment, remain deterministic across sampling
   rates, and preserve run endpoints when possible.
6. Gain/loss SHALL use a configurable trend-reversal deadband rather than sum
   every adjacent positive/negative delta, process each run independently, and
   avoid double-counting one hill.
7. A run with too few altitude samples SHALL keep a safe corrected fallback but
   SHALL NOT claim meaningful gain/loss; unavailable values SHALL NOT become
   fake zero altitude.

### Requirement 6: Share corrected elevation with every consumer

**User Story:** As a runner, I want summary, charts, maps, comparison, and
exports to agree on the same corrected route and elevation.

#### Acceptance Criteria

1. `WorkoutAnalyzer` SHALL construct one immutable `WorkoutAnalysisContext`
   containing `WorkoutTimeline` and `ElevationProfile`, then pass it to summary,
   splits, notable segments, and other core consumers.
2. Summary gain/loss, split ascent, and timeline elevation range APIs SHALL use
   the shared profile and SHALL NOT retain a raw adjacent-altitude implementation.
3. Biggest climb/descent SHALL select the largest threshold-confirmed corrected
   ascent/descent in a continuous reliable policy-defined window (20% of total
   distance clamped to 100...1,000 m by default); a flat noisy or unavailable
   profile SHALL NOT produce an impressive elevation highlight.
4. The elevation chart SHALL show corrected distance-aligned samples, preserve
   missing and segment gaps, keep distance seeking exact, and describe corrected
   values accessibly.
5. Elevation route colouring and projection SHALL use finite corrected values,
   preserve route gaps, and avoid a fake scale when elevation is insufficient;
   comparison route identity SHALL remain blue/orange.
6. Summary and distance-sampled comparison SHALL use corrected gain and
   corrected altitude, preserve unavailable values, and avoid interpolation
   across gaps.
7. JSON, CSV, and PNG output SHALL use corrected summary/split/highlight values
   and SHALL label corrected analysis separately from raw source altitude while
   retaining numeric and CSV-injection safety. A corrected descent export value
   SHALL be a positive magnitude matching the highlight subtitle; any retained
   signed compatibility delta SHALL be explicitly separate.
8. UI and platform consumers MAY retain immutable per-workout contexts but
   SHALL NOT introduce an unsafe global mutable cache.

### Requirement 7: Retain diagnostics and recover unobtrusively

**User Story:** As a runner, I want to know when the app repaired meaningful
signal problems without a successful import being treated as an error.

#### Acceptance Criteria

1. A backward-compatible Codable diagnostics value SHALL count invalid
   coordinates, discarded coordinate points, inferred gaps, discarded altitude
   samples, and invalid source speeds.
2. Importer-side coordinate filtering SHALL pass its invalid count into the
   shared processor rather than losing the diagnostic before timestamp
   resolution.
3. Retained warnings SHALL cover coordinate outliers removed, implicit gap
   introduced, altitude outliers ignored, and insufficient reliable altitude.
4. Ordinary smoothing SHALL NOT create a warning.
5. Recovered quality warnings SHALL use the existing unobtrusive warning UI and
   SHALL NOT become a blocking import error.

### Requirement 8: Version and stage normalization migration safely

**User Story:** As a runner with an existing library, I want legacy routes
upgraded once without losing identity, order, selection, or usable data.

#### Acceptance Criteria

1. `normalizationVersion` SHALL be independent of `analysisVersion`; missing
   versions SHALL decode as legacy `0`.
2. Migration order SHALL be compatible decode, required normalization, shared
   context construction, analysis recomputation, then atomic persistence.
3. A normalization upgrade MAY deliberately alter route points; an analysis-only
   upgrade SHALL preserve already-current normalized points.
4. Migration SHALL preserve workout ID, metadata, source, retained point IDs,
   compact route segments, library order, and selection, and SHALL recompute
   summary, splits, and highlights.
5. A failed upgrade write SHALL leave the prior disk snapshot intact, keep a
   usable workout visible in memory, report a warning, and remain retryable.
6. Already-current snapshots SHALL NOT be rewritten at every launch, and the
   manifest schema SHALL NOT change unless independently required.

### Requirement 9: Bound performance, propagate cancellation, and verify

**User Story:** As a maintainer, I want long routes to complete predictably and
cancelled imports to leave no partial library entry.

#### Acceptance Criteria

1. Processing SHALL support at least 100,000 points with O(n) or O(n log n)
   work, rolling/monotonic windows, bounded sorting, reserved storage, and no
   full-route scan per point. Timestamp gap resolution SHALL use linear passes,
   and distance-stepped consumers SHALL enforce a fixed evaluation budget.
2. Long coordinate and elevation loops SHALL check cooperative cancellation at
   a documented policy stride.
3. `CancellationError` SHALL propagate through interactive import as
   cancellation rather than parsing failure, and persistence SHALL NOT begin
   after cancellation. Derived analysis SHALL be assembled locally so a
   cancelled pass does not expose a partially updated workout.
4. Synthetic tests SHALL cover coordinate quality, elevation behavior,
   downstream consumers, migration, malformed values, cancellation, and
   100,000-point performance.
5. Manual route-quality checks SHALL remain unchecked unless actually
   performed, and exact automated commands and limitations SHALL be reported in
   the pull request.

## Non-goals

- moving-time estimation;
- map matching or online elevation correction;
- barometer, weather, training-load, HR-zone, calorie, or grade-adjusted-pace
  changes;
- batch import, cloud sync, or broad UI redesign.
