# Requirements: Swift engine scaffold

1. An internal, portable Swift 6 target builds with strict memory safety and
   warnings treated as errors. It is not a package product.
2. Engine sources may explicitly import only a platform C math module. Core is
   the only production layer allowed to import the engine, with internal access.
3. Swift Testing verifies shared parity primitives on macOS and in the pinned
   Linux container: deterministic input words, exact floating-point bit
   comparison, and a byte-ordered FNV-1a-64 digest.
4. All existing C++ kernels, callers, tests, and verification stay in place.
   No public API, serialization, persistence, or dependency version changes.
