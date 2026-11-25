# DEM tile planning and sampling Swift port design

Both kernels share `demPixelFootprint`, which classifies a coordinate and lists the
pixels a bilinear sample reads (only pixels with non-zero weight). Planning lists the
tiles of those pixels; sampling reads those pixels. The planner's tile set is bounded by
`maximumTileCount`, never by route length, and stops at the first tile beyond the budget.

The adapter converts coordinates once, plans, hands the planned tiles to Swift's
`loadTiles`, validates and sorts the decoded tiles into the directory order, packs the
heights, and samples. `tileBudgetExceeded` becomes the existing
`.tileBudgetExceeded(minimumRequiredTileCount:)` outcome, with `maximumTileCount + 1`.

## C++ status translation audit

| C++ status | Swift result | Verification |
| --- | --- | --- |
| `success` | owned result | Compared exactly on the corpus. |
| `invalid_input_buffer` | Unrepresentable: a `Span` cannot pair a positive count with null storage. | Native C++ tests only. |
| `invalid_output_buffer` | Unrepresentable: the engine owns the result. | Native C++ tests only. |
| `insufficient_output_capacity` | Unrepresentable: no caller capacity. | Native C++ tests only. |
| `invalid_policy` | `.invalidPolicy` (both kernels) | Compared: nine invalid policies. |
| `tile_budget_exceeded` | `DemTilePlanError.tileBudgetExceeded` | Compared: budgets four and five. |
| `invalid_tile_directory` | `DemSamplingError.invalidTileDirectory` | Compared: order, duplicates, out-of-grid keys, height count, budget. |
| `resource_limit` | `.resourceLimit` | Engine tests (ceiling plus one); too large to run through C++ here. |
| `allocation_failure` | Unrepresentable as a recoverable status. | Not injected. |
| `internal_failure` | `.internalFailure`, mapped to Core's engine contract violation. | Not reachable. |

## Literal-translation audit

- `floor` is `.rounded(.down)`; `isfinite` is `.isFinite`; `tan` and `asinh` call the
  platform libm, as the C++ code does, so macOS and Linux digests are captured separately.
- `std::clamp(v, lo, hi)` is `(v < lo) ? lo : (hi < v) ? hi : v`, written out for doubles
  and for `Int64`. `%` has C++'s truncating sign, and the column wrap handles negatives.
- The two `Double` to `Int64` conversions floor a value in `[-0.5, 2^36]`, so they cannot
  trap. The tile quotients are below 2^24 and fit `UInt32`. The height offset is at most
  65,536 x 2^24, inside `Int`.
- Statements that mix a multiply and an add are split, so Swift's two rounded operations
  match the C++ source, which splits them for `-ffp-contract`.
- The planner's sorted vector is a binary-searched array with `insert(at:)`, as in C++.
  No `std::sort` is involved.
