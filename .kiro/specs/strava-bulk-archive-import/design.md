# Design — Strava bulk-archive import

## Layers

| Layer | Ownership |
| --- | --- |
| **RunPlayCore** | Archive-independent models, CSV parser, GZIP decoder, path validation, sport policy, data-based importers, provenance, batch store API |
| **RunPlayPlatform** | Vendored ZIPFoundation access, SHA-256 hashing, `StravaArchiveService` scan/import actor |
| **RunPlayStudio** | Menu/picker, review/progress/report sheet, AppState orchestration, heatmap invalidation |

## Pipeline

1. **Scan** — open ZIP, validate paths, read `activities.csv`, build candidates + duplicate status.
2. **Review** — user selects importable rows.
3. **Import** — for each selected candidate: read entry → optional GZIP → SHA-256 → parse via `WorkoutImportInput` → apply metadata → stage snapshot.
4. **Commit** — promote staged files, one manifest write, select newest, one heatmap refresh.

## Provenance

`WorkoutImportProvenance` on `RunWorkout` (optional Codable). No analysis /
normalization / manifest schema bump. Never stores absolute archive paths or
account identifiers.

## Batch transaction

`beginBatchImport` / `stageWorkout` / `commitBatchImport` / `rollbackBatchImport`
on `WorkoutLibraryStoreActor` with `.staging/<batch-id>/` under the library root.
