# Swift engine 01: geodesy and route values

- Preserve all C++ geodesy operations at platform-local floating-point bit parity.
- Provide the Swift route input value and preserve the 25% internal-route ceiling margin.
- Do not switch a production geodesy or route-quality caller, expose the dead
  batch inspection or engine identity functions, or change the package graph.
- Leave the C++ sources, bridges and native checks for later stack entries.
