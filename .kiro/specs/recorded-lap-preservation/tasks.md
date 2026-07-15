# Tasks: Recorded Lap Preservation

- [x] Core models: `RecordedLap`, trigger, reported metrics, diagnostics
- [x] `RunWorkout` fields, Codable compatibility, analysis version 5
- [x] Timeline elapsed-time boundary API
- [x] `RecordedLapAnalyzer` with invariants, cancellation, mismatch aggregation
- [x] FIT lap association, field audit, session filtering
- [x] TCX lap metadata parsing and continuity resolver
- [x] JSON optional laps; GPX empty-laps policy
- [x] Analysis rederive preserving IDs; legacy reimport warning
- [x] Splits workspace dual mode, seek, current-lap highlighting
- [x] Ordinal lap comparison
- [x] Recorded Laps CSV, combined CSV, JSON export, PNG count line
- [x] Unit/importer tests (model, analyzer, timeline, FIT, TCX, continuity)
- [x] Documentation and Kiro specification
- [x] Full package build and test suite green

## Manual verification (when GUI available)

- [ ] Seamless TCX laps continuous route + clocks
- [ ] Multi-track pause gap retained
- [ ] FIT manual/distance triggers
- [ ] UI mode switch, seek, highlight
- [ ] Export + persistence + legacy reimport
