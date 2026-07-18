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
- [ ] Manual GUI verification with synthetic archive (owner)
- [ ] CI green on PR head
