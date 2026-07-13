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

Import formats and limits: #[[file:docs/import-formats.md]]
Architecture (importer section): #[[file:docs/architecture.md]]
