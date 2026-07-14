# Design Document

## Overview

The change moves route-quality decisions behind one `RunPlayCore`
`RouteQualityProcessor`. Every importer supplies raw points and a deliberate
distance policy; the processor returns normalized points, distance provenance,
diagnostics, warnings, and an aligned `ElevationProfile`. `WorkoutAnalyzer`
then builds one `WorkoutAnalysisContext` so clocks, corrected elevation,
summary, splits, and highlights share identical route boundaries and range
semantics.

Finite source altitude remains on `RoutePoint`, and normalization never rewrites
the original imported file. Rendering, comparison, replay metrics, and exports
consume immutable corrected analysis rather than independently filtering raw
samples.

## Non-goals

- map matching, Apple routing, geocoding, or network elevation correction;
- live tracking, cloud processing, telemetry, or AI services;
- moving-time estimation or a broad UI redesign;
- changing heart rate or cadence;
- fabricating altitude across a missing span or route gap.

## Ordered quality pipeline

1. **Basic validation** keeps valid coordinates, compacts explicit segments,
   normalizes within-segment order and elapsed values, ignores invalid optional
   horizontal-accuracy fields, preserves source heart rate/cadence, and removes
   impossible source speed/pace so later geometry can derive replacements.
2. **Isolated coordinate detection** evaluates each interior three-point
   neighbourhood. Both candidate legs must exceed the generous running-speed
   ceiling, the direct bridge must be plausible, and the detour must exceed a
   minimum length and distortion ratio. Poor candidate accuracy can strengthen
   this proof only when neighbours are better. Adjacent candidates and endpoints
   remain because the evidence is ambiguous.
3. **Implicit-gap detection** considers only a sufficiently large geographic
   jump supported by excessive implied speed or a long recording interval. A
   configurable following cluster must stay in the source segment, keep short
   mutually plausible steps, and contain enough points. The boundary is added
   before the cluster and all resulting segment indexes are compact.
4. **Distance normalization** chooses supplied or coordinate-derived distance
   per importer policy and segment validity, rebases each segment at the prior
   global endpoint, clamps the series non-decreasing, and stores provenance.
5. **Altitude sanitization** preserves source altitude but excludes values
   outside a broad Earth range, locally unsupported interior or one-sided run
   endpoint spikes, and extreme two-sample interior plateaus from the derived
   profile. Rejection is bounded by travelled normalized distance. An isolated
   rejected interior sample can be reconstructed only from immediate reliable
   neighbours in the same segment; rejected run endpoints and adjacent samples
   remain gaps.
6. **Distance-domain smoothing** divides altitude into continuous non-missing
   runs and applies a centered rolling average with monotonic left/right
   indices. It never crosses a source/inferred segment or missing span and
   restores run endpoints.
7. **Gain/loss calculation** applies a threshold-confirmed trend algorithm to
   each reliable run. Small reversals remain uncommitted; a reversal beyond the
   deadband commits the previous trend once. Prefix arrays expose cumulative and
   distance-range ascent, descent, and signed change.
8. **Diagnostics generation** persists quality counts, distance provenance, and
   meaningful non-fatal warning cases.

## Central policy

`RouteQualityPolicy.runningDefault` owns every threshold:

| Setting | Default | Design reason |
| --- | ---: | --- |
| Coordinate discontinuity speed | 12 m/s | Generous evidence threshold; not a sole deletion rule |
| Source speed ceiling | 15 m/s | Keeps legitimate sprint values while excluding impossible running data |
| Stale zero-speed movement | 1 m/s | Lets normalized geometry replace a recorded zero while movement clearly continues |
| Stationary source-speed ceiling | 1 m/s | Lets stationary normalized geometry replace a stale positive device speed |
| Source-speed/geometry disagreement | 4× | Allows ordinary device variance but rejects gross inconsistency |
| Useful horizontal accuracy | 100 m | Accuracy supports a neighbourhood decision without penalizing formats that omit it |
| Isolated-spike excess and distortion | 200 m and 3× | Requires a materially shorter plausible bridge |
| Poor-accuracy excess multiplier | 0.5 | Better neighbours may strengthen, but never independently prove, rejection |
| Relocation jump and long interval | 200 m and 120 s | Time alone does not create a gap |
| Long-gap cadence discontinuity | 3× | Avoids treating uniformly sparse sampling as a stop/resume boundary |
| Relocated-cluster proof | 3 points; 200 m fallback step | Uses plausible time-derived speed when timing is valid and the absolute fallback only when it is not |
| Legacy distance inference | max(20 m, 5% of geometry) | Requires material evidence before retaining a legacy non-GPX distance series as device-supplied |
| Plausible altitude | -500...9,000 m | Broad enough for below-sea-level through high-altitude running |
| Altitude-spike proof | 35 m deviation, neighbours within 12 m, 150 m maximum travelled span | Targets only a locally unsupported interior or one-sided run-endpoint error |
| Short altitude excursion | At most 2 samples, each 100 m from the returned baseline, 150 m maximum travelled span | Removes only an extreme bounded plateau, not a sustained terrain change |
| Smoothing radius | 15 m | A 30 m full window is stable across common sampling rates |
| Reliable altitude run | 2 samples | At least one interval is needed for gain/loss |
| Gain/loss deadband | 3 m | Suppresses flat jitter while preserving sustained trends |
| Elevation-highlight window | 20% of total distance clamped to 100...1,000 m | Defines the biggest climb/descent comparison window |
| Elevation-highlight step | max(25 m, window / 10) | Bounds evaluation count while preserving useful resolution |
| Cancellation stride | 2,048 points | Cooperative cancellation without per-point task overhead |

## Distance policy and source provenance

The four policies are coordinate-derived, all-or-nothing supplied distance,
valid supplied distance per segment, and an explicit set of proven supplied
segments. GPX uses coordinate-derived distance. TCX and JSON choose the complete
supplied series only when present and valid. FIT chooses valid supplied distance
per segment. Outlier removal precedes coordinate-derived distance, and inferred
or explicit boundaries contribute no geographic jump.

`RouteDistanceSource` summarizes the result as coordinate-derived,
device-supplied, mixed, or legacy-unknown. `RouteDistanceProvenance` aligns the
decision to compact segment indexes. Legacy GPX is coordinate-derived; other
legacy formats preserve a complete monotonic series only when its difference
from raw geometry provides evidence that it was device-supplied.

## ElevationProfile range semantics

`ElevationProfileSample` is aligned by retained `RoutePoint.id`, distance, and
segment. Corrected altitude is optional, rejection state is explicit, and
cumulative ascent/descent never decreases. The profile also keeps prefix arrays
for signed change and reliable intervals.

Distance queries use binary search and the same duplicate-distance boundary
roles as `WorkoutTimeline`: a range start selects the resumed point while a
range end selects the pre-gap point. Corrected altitude interpolation requires
both neighbours to share one continuous altitude run. Range gain/loss may
aggregate several reliable runs, but no individual delta or interpolation
crosses a gap. Notable climb/descent additionally requires both window
boundaries to share one reliable run.

The default notable-elevation window is 20% of total route distance clamped to
100...1,000 m and is evaluated every `max(25 m, window / 10)`. The largest
threshold-confirmed ascent/descent magnitude within one fully reliable window
becomes the highlight.

A one-sample altitude run retains its sanitized source value for safe display
but has no reliable interval, no meaningful profile total, and no elevation
highlight. Summary models retain finite compatibility defaults while profile
availability and warnings distinguish unavailable from a real zero.

## Shared analysis and consumer integration

`WorkoutAnalysisContext` contains exactly one `WorkoutTimeline` and one aligned
`ElevationProfile`. Analyzer, split, and segment services accept that context.
Compatibility entry points may construct a profile, but the primary analysis
path constructs it once.

| Consumer | Corrected behavior |
| --- | --- |
| Summary | Uses profile total ascent/descent |
| Splits | Uses profile range ascent; global distance may aggregate separate continuous runs |
| Notable elevation segments | Largest threshold-confirmed ascent/descent within one reliable run |
| Timeline and replay metrics | Delegate distance elevation to the aligned profile |
| Elevation chart | Uses corrected optional samples and separate series at segment/missing gaps |
| Route projection and colouring | Use corrected finite scale; insufficient elevation has no fake scale |
| Comparison | Uses corrected summaries and corrected distance samples with `nil` gaps |
| JSON | Carries corrected analysis plus normalization/provenance/diagnostics/warnings; segment metric/value pairs use positive ascent/descent magnitudes and retain a signed compatibility delta |
| CSV | Labels split gain and segment metric/value columns as corrected analysis |
| PNG | Labels summary elevation as Corrected Gain/Loss |

`AppState` may retain immutable contexts keyed to a workout signature so SwiftUI
and platform consumers avoid repeated full-profile work. There is no shared
mutable singleton cache. Comparison route colours remain blue and orange.

## Diagnostics and warning UI

`RouteQualityDiagnostics` persists counts for invalid coordinates, discarded
coordinate points, inferred gaps, discarded altitude samples, and invalid
source speeds. `WorkoutAnalysisWarning` adds four backward-compatible raw-value
cases for the meaningful route-quality events. The detail view displays them in
the existing non-blocking warning treatment. Normal smoothing remains silent.

JSON summary export carries normalization version, distance source/provenance,
diagnostics, analysis warnings, and an explicit corrected-elevation analysis
label. Segment JSON pairs `elevationMetric` with
`correctedElevationValueMeters`; ascent and descent are positive magnitudes
matching the highlight subtitle, while `elevationDeltaMeters` stays signed for
compatibility. CSV and PNG use explicit corrected-elevation labels. Raw route
altitude remains source data.

## Normalization and analysis migration

`RunWorkout.currentNormalizationVersion` is independent of
`currentAnalysisVersion`; an absent field decodes as version `0`. The load order
is:

1. decode the backward-compatible snapshot;
2. choose distance policy from persisted provenance or conservative legacy
   source inference;
3. run normalization when stale;
4. build the shared context and recompute summary, splits, and highlights;
5. atomically replace the snapshot once.

An analysis-only upgrade uses `reanalyzePreservingRoutePoints`. A normalization
upgrade intentionally uses the full processor and may remove an outlier or add
a gap while retaining every kept point ID. Identity, metadata, source, library
order, and selection remain unchanged. A save failure leaves the old file
intact, keeps a usable workout visible in memory with a warning, and retries
later.
Already-current workouts are not rewritten, and the library manifest schema is
unchanged.

## Performance and cancellation

Within-segment ordering is O(n log n). Timestamp resolution, validation,
distance rebasing, rolling smoothing, and cumulative trend calculation are
linear. With the default policy, neighbourhood confirmation is O(n × k), where
`k` is bounded to three relocated-cluster points or two altitude-excursion
samples. Profile distance queries are O(log n). Arrays reserve capacity,
smoothing uses monotonic bounds, and no per-point full-route scan or unsafe
global cache is used. FIT timer events are sorted once, matched to records with
one advancing record cursor, and applied during decode with one advancing
segment cursor, so many pause/resume boundaries remain O(n + e log e).

Distance-stepped split, segment, comparison, and chart work uses a fixed safety
budget: at most 100,000 evaluations, scaled to eight evaluations per route
point with a minimum of 1,000. Impossible split cardinality returns unavailable
instead of allocating an unbounded array.

Processor and elevation loops call the supplied cancellation probe every 2,048
points, and distance-stepped derived analysis checks during each evaluation.
Interactive import lets `CancellationError` escape as cancellation, assembles
analysis in a local copy before one final assignment, and checks again before
the library transaction. Library migration is synchronous and recovery-oriented,
so it invokes the same deterministic processor with a non-cancelling probe.

## Verification strategy

- Synthetic coordinate cases cover unchanged clean/sharp/out-and-back routes,
  isolated teleports with and without accuracy, coherent relocation, explicit
  boundaries, long timestamp intervals, supplied distance, point IDs, and
  source speed.
- Synthetic elevation cases cover flat jitter, gradual climb, climb/descent,
  negative elevation, isolated spike, steep climb, missing/sparse spans,
  segment boundaries, sampling rates, short routes, and 100,000 points.
- Downstream tests cover analyzer summary, splits, notable climb/descent,
  comparison, chart-aligned profile samples, route projection/colouring, and
  exports.
- Migration tests cover legacy decode, route alteration followed by reanalysis,
  identity/order/selection, one-time persistence, current no-op, and write
  failure.
- A 100,000-record FIT regression with 10,000 active timer segments covers the
  event-boundary and per-record segment-assignment complexity paths.
- Cancellation tests cover coordinate and elevation work plus no partial
  persistence. Manual GUI evidence remains separate and unchecked until run.
