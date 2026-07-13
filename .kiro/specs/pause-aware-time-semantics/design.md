# Design Document

## Overview

The change introduces `WorkoutTimeline` in `RunPlayCore` and routes every clock
consumer through it. Route timestamps remain elapsed; the active clock is a
derived prefix sum over continuous segments. Models, exports, and UI publish
explicit semantics while compatibility aliases keep existing source and legacy
snapshot decoding stable.

This design supersedes only the old route-fidelity spec's high-level rule that
splits and pace windows cannot cross a route boundary. They may now span a
boundary on the global cumulative-distance axis. The original low-level safety
invariant remains: no adjacent metric delta, smoothing, elevation calculation,
or geographic interpolation crosses a gap.

## Non-goals

- moving-time threshold estimation;
- elevation filtering, HR zones, calories, or smoothing redesign;
- synthetic points or geographic interpolation across route gaps;
- manifest schema changes or broad UI redesign.

## WorkoutTimeline algorithms and invariants

The initializer builds three safe arrays aligned to source route points:

1. elapsed seconds from each timestamp relative to the initial route timestamp.
   If the timestamps do not span but the normalized route has a positive final
   `elapsedSeconds`, that series provides the elapsed clock; otherwise invalid
   or regressing intermediate timestamps hold the prior position rather than
   borrowing separately stored elapsed values;
2. active seconds as a prefix sum of positive, finite adjacent timestamp deltas
   within the same `routeSegmentIndex`; invalid deltas add no active time;
3. non-decreasing cumulative distance.

Elapsed total is the sanitized final route timestamp minus the initial route
timestamp, with the normalized elapsed-series fallback for non-spanning
timestamps. In that fallback, elapsed is active because the source supplies no
reliable pause boundary. Active and paused totals preserve finite non-negative
invariants.
`DistanceSample` returns elapsed and active clocks plus a real source index.
`DistanceRange` subtracts those samples and exposes the covered source range.
The service never mutates the route or persists active time per point.

## Duplicate-distance boundary policy

A stop endpoint and resume point can share one cumulative distance. Exact range
starts select the resumed segment's first point; exact range ends select the
prior segment's final point. This keeps an exact-boundary pause out of both
neighboring splits while a pause inside a split remains part of that split's
elapsed duration. Interpolation is allowed only when both bounding points are in
one segment.

## Analyzer, split, and segment integration

`WorkoutAnalyzer` creates one timeline, calculates explicit summary clocks and
active/elapsed pace and speed, and passes that authority to split and segment
services. Splits advance by global 1,000 m boundaries and emit one final
remainder. HR includes valid samples from every covered segment; elevation
deltas skip segment changes. Fastest/slowest windows use active duration even
when their cumulative-distance range crosses a pause.

## Replay lookup and state

`PlaybackEngine` uses elapsed duration. Binary search returns the last point at
or before the replay clock. Within a continuous interval, active time advances;
between segments it holds and `isInRecordingGap` becomes true. Distance and
point metrics use the held endpoint. Exact resume selects the resume point, and
stepping changes only real point indexes.

## Comparison, export, and UI data flow

Comparison constructs a timeline for each route. Summary exposes elapsed,
active, paused, active-pace, and elapsed-pace deltas; active pace determines the
winner. Selected-distance samples use the explicit range-end role and expose
both clocks plus cumulative active pace. A 30-second pause-difference threshold
adds an informational warning.

JSON export version 2 and CSV/PNG models use explicit clock and pace names while
retaining additive aliases where source compatibility helps. SwiftUI summary,
replay, split, segment, comparison, sidebar, and export surfaces use Elapsed,
Active, Paused, and Active Pace labels plus help/accessibility explanations.

## Persistence migration and failure policy

`RunWorkout.currentAnalysisVersion` is independent of the library manifest.
Missing versions decode as `0`. `WorkoutLibraryStoreActor.loadLibrary()`
reanalyses stale snapshots while preserving identity, metadata, source, exact
route points, order, and selection. `FileWorkoutLibraryStore` atomically
replaces the snapshot. A failed replacement keeps the upgraded in-memory value,
reports a warning, leaves the old file untouched, and retries next launch.

Snapshots that predate `routeSegmentIndex` cannot reconstruct pause boundaries
that are absent from their stored route; those workouts require reimport.

## FIT validation-warning policy

The selected running session's scaled `total_elapsed_time` and
`total_timer_time` validate route elapsed and active clocks. The route remains
authoritative. A mismatch greater than `max(5 seconds, route value × 2%)`
produces a typed import warning surfaced by `AppState`.

## Verification strategy

- Core timeline and replay tests cover no/multiple/long/zero pauses, malformed
  and duplicate time, distance boundary roles, held gaps, exact resume, and
  stepping.
- Analyzer, split, and segment tests cover explicit clocks, a 600 m interrupted
  kilometre, several pauses, HR/elevation aggregation, and active-pace windows.
- Comparison and export tests cover same-active/different-pause routes, dual
  clocks at distance, warnings, explicit fields, non-finite safety, and CSV
  injection regression.
- A legacy JSON fixture proves decode and successful actor migration; a failing
  store proves non-destructive persistence failure.
- FIT and JSON tests prove route authority, segment preservation, and warnings.
- Final gates use warning-clean SwiftPM/Core, Xcode package scheme, and packaged
  app launch verification. Manual GUI claims are reported separately.
