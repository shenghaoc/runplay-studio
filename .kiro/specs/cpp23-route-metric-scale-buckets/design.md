# Design — C++23 Route-Metric Scale and Buckets

## Boundary

```text
RouteMetricProfileBuilder
    -> Swift raw interval extraction
    -> Swift distance-domain smoothing
    -> compact optional metric values + exact interval weights
    -> one assign_route_metric_scale_buckets call
    -> pure-Swift numeric scale + assignments
    -> Swift localized labels and public RouteMetricInterval values
    -> Swift RouteMetricProfile
```

## Native workspace

The Swift bridge allocates one input sample and one output sample per interval.
The engine validates pointers, capacity, count, policy, presence bytes, weights,
and index conversion before writing. It then initializes output from input,
sorts eligible entries in-place with `std::sort`, computes the three exact
distance-weighted quantiles, restores source order, and assigns normalization
and buckets. It allocates no route-sized native storage.

Eligible weighted samples have a present finite metric and a positive finite
weight. Weights are divided by the largest eligible weight before summation to
avoid overflow. Sorting is by value, weight, then source index. Quantiles clamp
finite inputs to `0...1`, use the first CDF crossing at
`cumulative + 1e-12 >= target`, and reject non-finite quantiles by producing no
scale, matching Swift.

A scale exists only when the valid-count and quantile requirements succeed and
`abs(upper - lower) + 1e-12 >= max(0, minimumScaleSpan)` is true. Equal bounds
normalize to `0.5`. Missing metrics remain no-data. Present metrics, including
zero-weight metrics, receive a normalized value and bucket when a scale exists.
No scale maps every interval to no-data.

## Swift bridge

`RunPlayRouteMetricScaleBucketBridge` alone imports the engine and translates
native values to internal pure-Swift result types. It enforces equal array
counts and the engine ceiling, performs stride cancellation checks during
conversion and translation plus immediately before and after the one native
call, and validates every summary and echoed output field. It never falls back
to Swift and no pointer escapes Interop.

## Non-goals

Metric extraction, smoothing, localized labels, Platform hysteresis/adaptive
chunking/coalescing, profile/cache policy, public API, persistence, UI, and the
final portable-core cleanup are outside this branch.
