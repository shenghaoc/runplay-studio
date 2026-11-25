# Personal heatmap coverage Swift port design

The kernel borrows one workout's route samples and returns an owned result: the counts and
the de-duplicated cells sorted by `(y, x)`. It performs Web Mercator projection, grid-cell
quantization, effective-segment gap breaking, supercover traversal and de-duplication in
one call. The adapter keeps one converted sample array per batch and slices it per workout.

## Differences from the C++ source that do not change results

- The visited-cell set is an open-addressing table, not `std::unordered_set`. The set is
  sorted by a total order before it leaves the kernel, so its iteration order is not
  observable.
- The supercover traversal inserts each cell as it is produced instead of collecting the
  interval in a vector first. Every collected cell was inserted when the interval ended,
  and the traversal keeps the last cell and the produced count that the vector's `back()`
  and `size()` supplied.
- The output is an owned array, so the capacity negotiation (`insufficient_output_capacity`
  and the second call) has no counterpart.

## C++ status translation audit

| `PersonalHeatmapCoverageStatus` | Swift result | Verification |
| --- | --- | --- |
| `success` | owned result with counts and sorted cells | Compared exactly on the corpus. |
| `invalid_input_buffer` | Unrepresentable: a `Span` cannot pair a positive count with null storage. | Native C++ test only. |
| `invalid_output_buffer` | Unrepresentable: Swift owns the result. | Native C++ test only. |
| `insufficient_output_capacity` | Unrepresentable: no caller capacity. The differential bridge negotiates it and the corpus records how often it did. | Native C++ test; compared through the bridge. |
| `invalid_configuration` | `PersonalHeatmapCoverageError.invalidConfiguration` | Compared: zero, negative, NaN and infinite cell size and interval, and zero cell budget. |
| `invalid_input_contract` | `.invalidInputContract`; the C++ kernel never returns it. | Mapped by the adapter. |
| `allocation_failure` | Unrepresentable as a recoverable status. | Not injected. |
| `internal_failure` | `.internalFailure`, mapped to Core's engine contract violation; the C++ kernel returns it only for an unexpected exception. | Not reachable. |

## Literal-translation audit

- `std::floor` becomes `.rounded(.down)`; `std::fmod` is `fmod`; `std::isfinite` is
  `.isFinite`; `std::sqrt` is `.squareRoot()`. `tan` and `log` call the platform libm, as
  the C++ code does, so the macOS and Linux digests are captured separately.
- `std::min` and `std::max` keep their argument semantics: `std::max(a, b)` is
  `(a < b) ? b : a` and `std::min(a, b)` is `(b < a) ? b : a`.
- `dx * dx + dy * dy` is split into two rounded operations so no multiply-add is fused.
- The only floating-point-to-integer conversion is the cell quotient. The C++ code rejects
  nonfinite quotients and quotients outside the `Int64` double range, and then converts a
  quotient of exactly 2^63, which is undefined behaviour there. That needs a cell size
  below 2.2e-12 m. Swift rejects it as out of range instead of trapping. This is the one
  input where behaviour is defined here and undefined in C++.
- `index + 1` in the boundary computation cannot overflow: a cell index is at most
  2^63 - 1024. The traversal stepping adds one per iteration, bounded by the cell budget.
- `maximum_cells_per_interval` is `size_t`. Core passes an `Int`; a negative value keeps
  its two's-complement meaning through `UInt(bitPattern:)`, as it did through the C++ call.
- There is no `std::sort` comparator tie: cells are unique and ordered by `(y, x)`.
