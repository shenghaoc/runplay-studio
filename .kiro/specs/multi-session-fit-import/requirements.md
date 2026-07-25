# Requirements — Multi-session FIT import

## User story

As a runner whose watch writes several sessions into one `.fit` file, I can
choose **Import File…**, review every session the file contains, and import the
supported running sessions as separate workouts in one atomic transaction —
without needing to know in advance whether the file holds one run or many.

## Functional requirements

1. **Import File…** stays the single entry point. No separate multi-session
   command is added.
2. A FIT file with zero session messages (legacy) imports directly through the
   existing single-workout path.
3. A FIT file with exactly one session message imports directly through the
   existing single-workout path, with field-level parity between direct import
   and `FITImporter.buildSession` for ordinary one-session files.
4. A FIT file with two or more session messages opens the **Import FIT
   Sessions** review sheet.
5. Non-FIT files (GPX, TCX, JSON) never reach the FIT scanner.
6. The review sheet lists every discovered session in **FIT source order** with
   status, date, sport, elapsed time, distance, GPS point count, and lap count.
7. Only `ready` sessions are selected by default. Duplicate, unsupported,
   no-GPS, boundary-invalid, ambiguous, over-limit, and parse-failed sessions
   are visible but not selectable.
8. Selected sessions are parsed individually; a per-session failure does not
   prevent valid siblings from being staged.
9. All successfully staged workouts commit together in one manifest update.
   Zero staged workouts roll back. A commit failure imports none of them.
10. The completion report distinguishes imported, already-imported,
    unsupported, no-GPS, ambiguous, failed, cancelled, and commit-failed.
11. After a successful commit the newest imported session (by start date, with
    source order as the tie breaker) is selected.
12. Cancellation at any point rolls back staging and reports a cancelled
    result rather than a parse error.

## Sport policy

FIT sport classification is centralised in `FITSportPolicy` and used by both
the scanner and the importer:

- `running` → supported.
- Missing sport, or a sport value outside the known profile enum → treated as
  running, carrying an explicit "unknown sport" warning. This preserves the
  pre-existing FIT importer fallback.
- Every other known profile sport, **including walking and hiking**, is
  unsupported. This matches the existing FIT single-session policy on `main`,
  which only selects `FITSport.running`. It intentionally differs from
  `StravaActivityTypePolicy`, whose walk/hike acceptance applies to Strava
  bulk-export rows, not to FIT session messages.

## Attribution requirements

1. Session start prefers a valid `start_time`, then a valid end timestamp minus
   a valid `total_elapsed_time`.
2. Session end prefers a valid session `timestamp`, then the next session in
   **FIT source order** (not time-sorted) when its resolved start is ≥ this
   session's start — as a bounded conservative fallback.
3. A session with no reliable start, or no reliable end and no next boundary,
   is not importable.
4. Records, events, and laps without a usable timestamp are excluded in
   multi-session mode. They are never guessed into a session.
5. Boundary policy: session start is inclusive; session end is inclusive only
   when it does not equal a later session's start. A shared boundary timestamp
   belongs to the **later** session.
6. Materially overlapping session ranges mark both sessions ambiguous.
   Overlapping records are never assigned by guesswork. Lap index metadata does
   not resolve time-range overlap.
7. Laps are associated by `first_lap_index` + `number_of_laps` (lower 12 bits
   of `message_index`) first, then by timestamp range, then not at all. One lap
   never appears in two workouts.
8. Timer events remain authoritative for pause/resume route segmentation and
   are scoped per session. A session boundary is not a pause event.
9. Source timing warnings compare a workout only against its own session
   totals.

## Complexity requirements

- Session preparation: `O(s log s)`.
- Record attribution: `O(r + s)` after preparation (`O(r log r)` extra only
  when source record order is not chronological).
- Event attribution: `O(e + s)` after preparation.
- Lap attribution: `O(l + s)` after preparation.
- The whole container is parsed at most once per phase; individual sessions are
  decoded from the shared `FITDecodedFile`, never by re-reading the binary.

## Identity requirements

1. New provider case `WorkoutImportProvider.fitMultiSessionFile`.
2. New optional `WorkoutImportProvenance.sourceContainerSHA256` — lowercase hex
   SHA-256 of the whole original FIT container. Old snapshots decode as `nil`.
3. `providerActivityID` is `fit-session-v1:<sha256 of identity tuple>` where the
   tuple covers container hash, source session ordinal, raw start and end
   timestamps, sport, sub-sport, first lap index, and lap count. Session
   `message_index` is not part of the tuple until the decoder parses it (then
   bump the version prefix).
4. Same file → same IDs. Renaming the file does not change IDs. Sibling
   sessions differ. Identical session metadata in two different containers does
   not collide.
5. Exact duplicate = existing provenance provider is `.fitMultiSessionFile`
   **and** `providerActivityID` matches. A shared container hash alone never
   marks siblings duplicate.
6. No locale-formatted dates, absolute paths, account identifiers, or raw
   fingerprints in user-visible names.

## Resource requirements

`FITMultiSessionImportPolicy` centralises: maximum container bytes (reusing the
existing 100 MB FIT parser limit), maximum scanned sessions (256), maximum
selected sessions (100), maximum records, events, and laps, cancellation-check
stride, and maximum candidate display-name length. Only local `file:` URLs are
read. Security-scoped access is held for the whole scan → review → import
lifetime and released on dismissal.

## Accessibility requirements

Default and cancel key actions are wired (same idiom as the Strava archive
sheet), with VoiceOver labels and values for every row and control, a live
selected-count value, status conveyed by text rather than colour alone, and
participation in the existing modal command-blocking architecture. Escape-to-
cancel and a full VoiceOver pass remain manual verification items
(see `docs/manual-testing.md`).

## Non-goals

Cycling/swimming import, multisport merging, triathlon visualisation, nested
batch review inside Strava archive import, user editing of FIT session
boundaries, duplicate merging, fuzzy duplicate detection, multi-file picking,
Garmin API, HealthKit, video export, cloud sync, telemetry, analytics, AI.

## Known limitation

A Strava bulk-export archive entry that itself contains several running
sessions stays fail-safe: it is reported as unsupported/ambiguous for that
entry. Nested batch review inside archive import is out of scope.
