# Preserve unavailable workouts

A snapshot that cannot be read or decoded remains in the manifest with its original bytes, favourites, tags, and route associations. A fresh load still displays readable workouts, reports the unavailable rows, and recovers the original rows when their snapshots are readable again.

Do not replace an existing snapshot with a representation that loses stored JSON. Do not delete a final snapshot merely because its ID is absent from the manifest. Recovery may remove identified abandoned import staging directories.

There is no persisted schema change, public API change, or new dependency.
