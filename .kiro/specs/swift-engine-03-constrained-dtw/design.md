# Constrained-DTW Swift port design

`RunPlayEngine` borrows two spans and returns an initialized Swift path or a typed error.
It preserves the C++ row layout, cost evaluation order and tie-breaking. Costs,
steps and warp runs are packed by row. The adapter owns conversion, cardinality,
diagnostic translation and cancellation. The C++ bridge and marshalling are
compiled only in the Core test target; both production services call the Swift
adapter directly.

The differential corpus compares raw cost bits and complete paths. Native C++
canaries detect writes on failure; Swift cannot expose a partially initialized
output because the result is owned. The native pointer/null and caller-capacity
cases remain in the C++ harness by construction. Swift allocation is not a
recoverable C++ exception; no allocation-failure status is synthesized.

## C++ status translation audit

The native enum has one success value and ten failure values. Every value is
accounted for below. “Compared” means the live Core differential corpus checks
both adapters' observable result, including untouched native output on failures.

| `RouteAlignmentDtwStatus` | Swift result | Verification |
| --- | --- | --- |
| `success` | Returned owned `RouteAlignmentDtwPath` | Compared: complete path, exact indices and steps, radius, packed cell count and cost bits. |
| `invalid_primary_buffer` | Unrepresentable: a borrowed input span cannot express positive count with null storage. | Native C++ buffer test only. |
| `invalid_comparison_buffer` | Unrepresentable for the same span invariant. | Native C++ buffer test only. |
| `invalid_output_buffer` | Unrepresentable: Swift owns output and accepts no caller-supplied output pointer. | Native C++ buffer test only. |
| `insufficient_output_capacity` | Unrepresentable: Swift has no caller-supplied capacity; it allocates under the proven path bound. | Native C++ short and null/zero-capacity output tests only. |
| `invalid_policy` | `RouteAlignmentDtwError.invalidPolicy` | Compared: nonfinite policy. |
| `invalid_input_contract` | `RouteAlignmentDtwError.invalidInputContract` | Compared: empty input, nonfinite samples and invalid dimensions. |
| `resource_limit` | `RouteAlignmentDtwError.resourceLimit` | Compared: estimated and packed cell budget failures. |
| `no_path` | `RouteAlignmentDtwError.noPath` | Compared: finite path cost above the unreachable sentinel. |
| `allocation_failure` | Unrepresentable as a recoverable status: Swift collection allocation does not throw C++ `std::bad_alloc`. | C++ catch retained; allocation failure is not injected by the corpus. |
| `internal_failure` | `RouteAlignmentDtwError.internalFailure`, mapped to Core's engine contract violation. | Invariant guard retained, but no fixture corrupts kernel-produced predecessors or injects an unexpected C++ exception. An unexpected failure fails the differential rather than joining the digest. |
