# Design

Port the C++ passes in order: plausibility, endpoint spikes, interior spikes, excursions, interpolation, run classification and smoothing, and cumulative gain/loss. The output samples carry temporary fill and smoothing values in the same fields used by the native kernel, then those fields are cleared before cumulative results.

The adapter owns conversion and cancellation checks; the pure engine takes a Span and a value policy. Transitional coverage compares the same Core fixtures through both adapters and pins per-platform native corpus digests. Runtime measurements remain in the PR body.
