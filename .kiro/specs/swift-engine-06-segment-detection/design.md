# Segment-detection Swift port design

Borrow a span of compact timeline/elevation samples. Preserve native search order,
bounds, strict first-winner ties, plateau role differences, and interpolation
operation order. Elevation reuses its two deterministic location results across
the cumulative fields. The positive search budget is checked before stepping;
never truncate a floating-point quotient into an integer.

The adapter owns input compaction and output validation. The C++ reference and
its marshalling are compiled only in `SegmentDetectionDifferentialTests.swift`.
An alias preserves existing service calls; neither production caller enters the
C++ reference. Fixed output is internal to the engine.
Conversion rolls diagnostic categories and cancellation back into the existing
Core contracts. Release verification compares complete adapters with identical
Core inputs and the existing durable end-to-end highlight digest.

## C++ status translation audit

The kernel throws `SegmentDetectionError`, which mirrors `SegmentDetectionStatus`
minus the cases a `Span` and an engine-owned fixed result make unrepresentable.
The adapter switches over it exhaustively. "Compared" means the live Core
differential corpus checks both adapters' observable result.

| `SegmentDetectionStatus` | Swift result | Verification |
| --- | --- | --- |
| `success` | Fixed result with a written prefix and both evaluation counters | Compared: every candidate field by bit pattern and both counters. |
| `invalid_input_buffer` | Unrepresentable: a borrowed span cannot pair a positive count with null storage. | Native C++ buffer test only. |
| `invalid_output_buffer` | Unrepresentable: the engine owns the fixed ten-entry result. | Native C++ buffer test only. |
| `insufficient_output_capacity` | Unrepresentable: no caller-supplied capacity exists. | Native C++ short-output test only. |
| `invalid_configuration` | `SegmentDetectionError.invalidConfiguration` | Compared: nonfinite step in the raw corpus. |
| `invalid_input_contract` | `SegmentDetectionError.invalidInputContract` | Compared: nonfinite distance and clock fixtures. |
| `resource_limit` | `SegmentDetectionError.resourceLimit` | Compared: evaluation budget of one and a quotient past `UInt64`. |
| `internal_failure` | `SegmentDetectionError.internalFailure`, mapped to Core's engine contract violation. | Not reachable from any fixture. |

Arithmetic checks: the only `Double` to integer conversions are the evaluation
counts, which are checked against the budget before conversion. The distance
windows use floating-point comparisons and no `std::sort`, so no comparator needs
a tie proof. Winner selection keeps the C++ strict first-winner rule.

