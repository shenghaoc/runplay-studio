# Design: Native Route Metric Coloring

## Architecture

```
RunPlayCore
  RouteMetricColorPolicy
  RouteMetricProfileBuilder  → RouteMetricProfile (intervals, scale, buckets)
  DistanceWeightedStatistics
  RouteColorMetrics (thin adapter for legacy SceneKit callers)

RunPlayPlatform
  RouteMapLineStyle.metric(mode, bucket)
  RouteMetricMapLineBuilder  → bounded [RouteMapLine]
  RouteMetricPalette (NSColor / hex stops)
  RouteColoringService (palette adapter over profile)

RunPlayStudio
  WorkoutRouteMapViewModel (cache, cancellation, preference mode)
  MapReferenceView + RouteMetricLegendView
  RouteMapCanvas stroke for metric styles
```

Dependency direction remains `Studio → Platform → Core`.

## Metric semantics

| Mode | Value | Scale direction | Missing |
|------|-------|-----------------|---------|
| Solid | n/a | n/a | primary blue |
| Pace | active s/km | lowerIsBetter (fast→0) | no-data gray |
| HR | bpm | higherIsMore | no-data gray |
| Elevation | corrected m | higherIsMore | no-data gray |

Scales use distance-weighted 10th / median / 90th quantiles.

## Line budget

1. Coalesce adjacent same-segment same-bucket intervals.
2. Hysteresis merges isolated one-interval flicker.
3. If line count > policy maximum, grow minimum chunk distance and assign
   distance-weighted median buckets per chunk (never drop segments or bridge gaps).

## UI

- `@AppStorage("routeColorMode")` preference only.
- Unavailable preferred mode renders Solid with concise help; preference retained.
- Legend shows numeric ends + median + relative caption; coverage when < ~92%.
- Builds run in `Task.detached` with serial suppression; prior route stays visible.
