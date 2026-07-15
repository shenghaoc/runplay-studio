# Design Document

## Overview

`WorkoutTimeline` remains the authority for elapsed, active, paused, replay,
and distance-boundary semantics. `MovementProfile` adds a second, estimated
partition inside active time. It classifies route intervals with geometry-first
evidence, applies hysteresis and dwell rules, and produces cumulative moving and
stopped clocks without mutating route points.

## Data flow

`WorkoutAnalyzer` receives post-quality-pipeline points and a timeline. It
constructs or reuses one immutable `MovementProfile`, then derives summary and
split fields plus diagnostics. `WorkoutAnalysisContext` shares that profile with
comparison, replay, and export consumers. AppState owns an immutable,
main-actor cache for comparison scrubbing; core services do not introduce a
mutable cache.

For a partial distance interval, the profile interpolates cumulative movement
and stopped clocks between the active clocks of the surrounding continuous
points. Range-start and range-end roles preserve the timeline's handling of
duplicate-distance pause/resume points.

## Persistence and presentation

`RunSummary`, `RunSplit`, and `RunWorkout` add movement fields and diagnostics.
The analysis version advances so stale library entries are reanalysed. JSON,
CSV, and PNG names explicitly mark estimated movement values. SwiftUI adds
compact estimated labels, help text, and an accessible stopped/paused state;
existing Pace remains active-time based.

## Non-goals

- automatic pause mutation or new route segments for traffic-light stops;
- map matching, online processing, cloud sync, or user-tunable thresholds;
- broad UI redesign or a second timeline implementation.
