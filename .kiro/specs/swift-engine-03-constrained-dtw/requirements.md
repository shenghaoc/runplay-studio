# Constrained-DTW Swift port requirements

- Preserve every representable C++ path result, floating-point cost bit, and error category.
- Preserve the band estimate before allocation and the exact packed check, fixed tie priority, open ends, warp cap, and proven path bound.
- Switch both consumers to one synchronous Swift call without changing service call sites, cancellation, public APIs, or persistence.
- Retain the C++ implementation for parity and benchmark coverage until the stack removes C++.
- Verify full-adapter release medians against C++, including the maximum-band probe and the product-limit import boundary.
