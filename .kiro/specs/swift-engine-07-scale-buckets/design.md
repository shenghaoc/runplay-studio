# Scale and bucket migration design

The kernel borrows a span of `(metric, weight, present)` samples and returns an owned
result: a summary, an optional scale (lower, median, upper) and one output sample per
input. It validates before allocating, skips compaction and sorting when a scale is
known to be impossible, and otherwise sorts only the quantile-eligible pairs in an
internal workspace. Corrected-elevation finalization stays in Swift by design.

## Decision: stable sort and the signed-zero tie (intended behaviour change)

The C++ kernel orders eligible pairs by metric and then weight with `std::sort`, whose
order for equal keys is implementation-defined. `+0` and `-0` compare equal, and the
selected quantile returns the raw metric, so the tie is observable in the bits.

I ran the unchanged C++ source on one input (32 samples, weight 1, metrics repeating
[0, 1, 0, 2] with index 26 replaced by `-0`; quantiles 0 and 1, five buckets):

| Host | C++ library | Median bits |
| --- | --- | --- |
| macOS arm64 | libc++ | `0x8000000000000000` (`-0`) |
| Linux aarch64, pinned image | libstdc++ | `0x0000000000000000` (`+0`) |

So no single C++ result exists. The owner decided (2026-11-24) to use Swift's stable sort
and not to port or change the C++ sort. The Swift result is deterministic on every
platform: ties keep source order, so the witness median is `+0`
(`0x0000000000000000`). This is recorded as an intended behaviour change.

How it is verified:

- The differential test is bit-exact on every field except in cases where equal-weight
  eligible `+0` and `-0` metrics both occur. For those it asserts numeric equality, and
  the PR body lists them. The check for such a case is a pure function of the input, so
  the list is the same on every platform.
- The golden digest is captured from the Swift kernel, one value for every platform,
  because a C++-derived digest would itself depend on the platform.
- A dedicated test pins the Swift result of the 32-sample witness at the engine and the
  Core level.

`Array.sort(by:)` is stable in the current standard library but not documented as
guaranteed. The witness tests fail if that changes.

## Sorting by distinct key

A plain stable sort of every eligible sample ran 1.2x to 1.5x the C++ time on the
duplicate-heavy release fixture (R6), because `std::sort` handles many equal keys in
near-linear time. The kernel therefore groups samples by `(metric key, weight)` in an
open-addressing table, sorts only the distinct keys with Swift's stable sort, and walks
each group's increment `count` times. That is the same sequence of floating-point
operands in the same order as a sum over the fully sorted array, so every bit is
unchanged. The only member of a group that can differ is a zero metric, whose sign is
taken from the source-order sign list for its weight. The metric key maps `+0` and
`-0` to one key, as the C++ comparator does. The golden digest, the witness tests and
the differential corpus check the equivalence.

## C++ status translation audit

`RouteMetricScaleBucketError` mirrors `RouteMetricScaleBucketStatus` minus the
unrepresentable cases. A `Span` cannot pair a positive count with null storage, and the
kernel owns its output and workspace.

| `RouteMetricScaleBucketStatus` | Swift result | Verification |
| --- | --- | --- |
| `success` | owned result, one output per input | Compared on the corpus. |
| `invalid_input_buffer` | Unrepresentable: null input with a count. | Native C++ test only. |
| `invalid_output_buffer` | Unrepresentable: Swift owns the output. | Native C++ test only. |
| `invalid_workspace_buffer` | Unrepresentable: the workspace is kernel-internal. | Native C++ test only. |
| `insufficient_output_capacity` | Unrepresentable: no caller capacity. | Native C++ test only. |
| `insufficient_workspace_capacity` | Unrepresentable: no caller capacity. | Native C++ test only. |
| `invalid_policy` | `.invalidPolicy`; C++ never returns it, and Core checks the policy before the call. | Mapped by the adapter. |
| `invalid_input_contract` | `.invalidInputContract` | Compared: presence byte, negative, NaN and -inf weights. |
| `resource_limit` | `.resourceLimit` | Compared: ceiling plus one. |
| `internal_failure` | `.internalFailure`, mapped to Core's engine contract violation; C++ never returns it. | Not reachable. |

## Literal-translation audit

- The only `size_t` subtraction is `eligibleCount - 1` in the quantile fallback. The
  branch cannot run when the eligible count is zero, which is excluded earlier.
- The only floating-point-to-integer conversion truncates the scaled bucket. The early
  nonpositive check and the finite and final-bucket guards run first, so the `Int64`
  conversion never traps, including for `Int64.max` buckets.
- `std::max`/`std::min` argument semantics are kept: the first argument wins for NaN.
- `std::sort` is the only sort. Its comparator is a strict weak order on finite values.
  Tied elements differ only by the sign of zero, which is the recorded behaviour change.
- Contract validation runs before any output is written, and the structural no-scale
  path runs before compaction and sorting. Positive infinite weight is valid input and
  valid coverage but not quantile-eligible. `-0` weight passes validation but is not a
  positive weight.
- The caller-owned workspace becomes an internal array reserved to the eligible count.
