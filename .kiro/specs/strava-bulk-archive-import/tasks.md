# Tasks — Strava bulk-archive import

- [x] Core models, security policy, path validation, sport policy
- [x] RFC 4180 CSV parser + Strava column mapping
- [x] GZIP decoder with CRC/size limits
- [x] Data-based importer entry points + provenance on `RunWorkout`
- [x] Batch staging transaction on library store
- [x] Platform `StravaArchiveService` + vendored ZIPFoundation 0.9.20
- [x] Studio UI: review / progress / report + menus
- [x] Core + Platform tests
- [x] Documentation + third-party notices + Kiro spec
- [x] Focused packaged-app smoke: menu, review, import, report, and replay
- [ ] Extended manual archive checklist: cancellation, re-import, heatmap, relaunch, and deletion
- [ ] CI green on PR head
