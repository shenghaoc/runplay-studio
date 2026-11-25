# Route-quality geometry requirements

Replace the C++ route-quality geometry call in production with the Swift
engine without changing output bits or Core's public interface. Keep stage 1
validation, speed checks, elevation, diagnostics and persistence in Core.

Use the route value from the geodesy port and a borrowed optional selection.
The returned output array is the only route-sized kernel workspace. Verify
the C++ native cases, differential corpus and per-platform C++ goldens before
removing the old engine. Check the complete route-quality bridge under the
release benchmark, including the one-million-point product limit.
