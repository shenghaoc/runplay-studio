# Scale and bucket migration

Move the route metric numeric finalizer to the Swift engine. Keep route metric policy,
cancellation, public models, and corrected-elevation finalization in Core.

- Every output field is bit-identical to the C++ kernel, with one recorded exception:
  equal-weight `+0` and `-0` metrics (see the design).
- One synchronous engine call per assignment; call sites do not change.
- Retain the unchanged C++ kernel only as a differential and benchmark oracle until
  the stack removes C++.
