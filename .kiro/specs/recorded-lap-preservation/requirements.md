# Requirements: Recorded Lap Preservation

## Problem

RunPlay Studio calculated kilometre splits but discarded source-recorded laps
from FIT and TCX. Users could not distinguish device laps from generated
splits, and lap data could not survive persistence, comparison, export, or
replay.

## Requirements

1. Preserve source-recorded laps as `RecordedLap`, separate from `RunSplit`.
2. Keep route-derived metrics canonical; retain source-reported metrics for provenance.
3. Map FIT `lap_trigger` and TCX `TriggerMethod` without guessing undocumented values.
4. Associate FIT laps only with the selected session; never create route segments from laps.
5. Parse TCX lap summaries; a lap boundary alone never creates a route gap.
6. Use `TCXRouteContinuityResolver` for multi-track continuity decisions.
7. Extend `WorkoutTimeline` with elapsed-time boundary sampling.
8. Analyse laps in O(route + laps) via `RecordedLapAnalyzer` with cooperative cancellation.
9. Persist laps with backward-compatible decoding; legacy snapshots stay empty without fabricating data.
10. Bump analysis version; rederive lap metrics while preserving IDs and source fields.
11. Splits workspace offers Distance Splits vs Recorded Laps when laps exist.
12. Replay exposes current recorded lap and supports seek-to-lap-start.
13. Comparison keeps split comparison and adds ordinal lap comparison only.
14. Export Recorded Laps CSV, combined CSV section, and JSON fields distinctly labelled.
15. Document terminology, format support, and reimport policy.

## Non-goals

- Inferring laps from GPX or from calculated splits
- Full FIT/TCX profile support
- Replacing calculated split comparison with lap comparison
- Fabricating laps for legacy library snapshots
