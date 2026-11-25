# Design

Translate the geodesy formulas from `Geodesy.cpp` without reassociating the
operations, wrapping the projection, or clamping antipodal results. Use only
the platform C math module and the Swift standard library.

The route builder continues to use its existing C++ buffer. The Swift engine
adds an owning value for later borrowed Span input, not a new batch function.
The existing Core limit reads the equivalent Swift constant.

The Core differential test imports the Swift engine directly. Only Core test
files named `*DifferentialTests.swift` may do so; no production bridge is
needed for the Swift oracle.
