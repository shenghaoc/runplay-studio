# Requirements — Strava bulk-archive import

## User story

As a runner with an existing Strava history, I can import supported running
activities from a **local** Strava bulk-export ZIP into my RunPlay Studio
library, review candidates before import, and rely on safe, idempotent,
transactional persistence — without Strava login or network access.

## Functional requirements

1. User can choose **Import Strava Archive…** and select one `.zip` file.
2. App scans the archive without unpacking it fully to disk.
3. App shows a review sheet with candidates, statuses, search, and selection.
4. Default selection covers ready running (and walk/hike) activities only.
5. Import processes selected candidates with progress and Cancel.
6. Valid activities commit atomically to the library; failures are reported.
7. Re-importing the same archive adds zero exact duplicates.
8. Provider ID + different content is a non-overwriting conflict.
9. Personal heatmap refreshes once after a successful commit.
10. Single-file import, comparison, and demo-library policy remain intact.

## Non-goals

- Strava OAuth/API, accounts, cloud sync, social data, photos, nested ZIPs,
  Garmin Connect archives, HealthKit, multi-session FIT expansion, AI.

## Security requirements

- Path traversal, absolute paths, symlinks, encrypted entries rejected/skipped.
- Finite resource limits for size, entry count, compression ratio, concurrency.
- Reject duplicate normalized ZIP paths and declared ZIP64 sizes that cannot be
  represented safely; revalidate entry-count and cumulative selected-size limits
  when reopening the archive for import.
- Verify each extracted ZIP entry's CRC before parsing it.
- GZIP: validate header/CRC/size; one layer; no recursive decompress.
- No shell-out to `unzip`/`ditto`/Python.
