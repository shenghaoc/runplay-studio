---
inclusion: fileMatch
fileMatchPattern:
  - "RunPlayCore/Sources/Importers/**/*"
  - "RunPlayCore/Tests/RunPlayCoreTests/FIT*"
  - "RunPlayCore/Tests/RunPlayCoreTests/GPX*"
  - "RunPlayCore/Tests/RunPlayCoreTests/TCX*"
  - "RunPlayCore/Tests/RunPlayCoreTests/JSON*"
  - "docs/import-formats.md"
---

# RunPlay Studio importer references

Use the live repository sources rather than duplicating format rules here.

All importers conform to `WorkoutImporting`; `WorkoutImporterFactory` dispatches
by file extension. After parsing, every importer passes its output through
`RoutePointSanitizer` before any analysis or persistence.

`WorkoutImportServicing.importWorkout` always returns exactly one `RunWorkout`.
Multi-session FIT is a separate service (`FITFileScanning` /
`FITSessionBatchImporting`), not a widening of that contract.

`FITImporter.buildSession(index:sessionIndex:suggestedName:provenance:)` is the
single FIT workout builder. The direct importer resolves the existing selection
policy and delegates to it; batch import calls
`FITDecoder.decodeRawResult(index:sessionIndex:)` directly. Never add a second
FIT construction path. Sport classification lives only in `FITSportPolicy`, and
session attribution only in `FITSessionAttribution` / `FITSessionMessageIndex` —
build the message index once per container, never once per session.

Import formats and limits: #[[file:docs/import-formats.md]]
Architecture (importer section): #[[file:docs/architecture.md]]
