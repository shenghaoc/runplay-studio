# Requirements

- Preserve the native elevation pipeline, ordered floating-point operations, typed failure mapping, and the existing cancellation/continuity rules at the Core boundary.
- Borrow compact input with a Span. Use the output array as the only route-sized kernel workspace, after validating every failure condition.
- Keep one production adapter call, existing DEM-source and parity checks, and untouched native sources until PR10.
