# Prompt: Harden GPX Import

## Context

RunPlay Studio is a macOS app for post-run visualization. The GPX importer exists but needs hardening for real-world GPX files.

## Task

Improve the GPX importer in `RunPlayStudio/Sources/Importers/GPXImporter.swift` to handle:

1. **GPX extensions** - Parse heart rate and cadence from common extension namespaces:
   - Garmin TrackPointExtension (`gpxtpx:hr`, `gpxtpx:cad`)
   - Cluetrust extensions
   - Generic `<hr>` and `<cad>` elements

2. **Route vs Track** - Support both `<trk>` (track) and `<rte>` (route) elements

3. **Multiple segments** - Handle `<trkseg>` elements within a track

4. **Metadata extraction** - Parse `<name>`, `<desc>`, `<time>` from GPX metadata

5. **Error handling** - Provide clear error messages for:
   - Missing coordinates
   - Invalid coordinate values
   - Empty tracks
   - Malformed XML

6. **Test with real files** - Add test cases using real-world GPX files from:
   - Strava export
   - Garmin Connect export
   - Apple Watch export via Workoutdoors

## Files to Modify

- `RunPlayStudio/Sources/Importers/GPXImporter.swift`
- `RunPlayStudio/Tests/RunPlayStudioTests/GPXImporterTests.swift` (create)

## Acceptance Criteria

- [ ] Parses GPX files from major fitness apps
- [ ] Extracts heart rate from Garmin extensions
- [ ] Handles multiple track segments
- [ ] Provides clear error messages
- [ ] Unit tests pass with sample GPX files
