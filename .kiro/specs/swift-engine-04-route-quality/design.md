# Route-quality geometry design

Core passes one ordered route and an optional selection to the kernel. The
kernel validates the resource limit, policy, input and selection before
allocating any output. Output is initialized once and used as the mutable
workspace for outlier marking, adjacent-candidate retention, gap inference,
segment compaction and distance normalization. Preserve the native pass order
and the segment-local supplied-distance scan.

The existing service call remains in place. The Swift adapter carries the
same pre- and post-call cancellation checks and projects the engine result
back into Core's route points and provenance. C++ remains available only
for the transitional parity and benchmark paths, with no error-driven
fallback.

## Translation audit

There is no floating-point-to-integer conversion and no sort in this
kernel. Neighbour indexes are used only inside the range that excludes both
endpoints. The resource ceiling also bounds segment counts, lookahead
sentinels and start/end arithmetic. The policy's unsigned confirmation
count can equal the native type's maximum; its addition wraps explicitly,
while an incomplete lookahead still reports the same sentinel.

Preserve the first operand on an equal C++ maximum, including signed zero.
Input validation intentionally does not check the first sample's optional
accuracy; the native first-iteration segment check runs before it. A
successful call returns one output per input. A thrown call returns no
partially initialized array.
