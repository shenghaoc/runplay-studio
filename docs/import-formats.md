# RunPlay Studio - Import Formats

RunPlay Studio imports workout files locally. Imported data stays on the Mac; the
app does not upload files, create accounts, call analytics, or use AI APIs.

## Supported Formats

| Format | Status | Notes |
| --- | --- | --- |
| JSON | Full support | Native fixture format with route points, metadata, biometrics, optional recorded laps, versioned route normalization, and versioned derived analysis. Legacy snapshots are normalized before they are reanalysed. |
| GPX | Track support | Parses `trk/trkseg/trkpt` GPS trackpoints, time, elevation, heart rate, and cadence extensions. Each track segment remains disconnected; waypoints and routes are ignored. Standard GPX does **not** define device laps — `recordedLaps` stays empty and `<trkseg>` is never treated as a lap. At least one timestamp is required for elapsed/active pace analysis; partial missing timestamps are interpolated. |
| TCX | Track support | Parses one GPS-bearing activity's laps (including summary fields and `TriggerMethod`), tracks, trackpoints, distance, elevation, heart rate, and cadence. A `<Lap>` boundary alone does **not** create a route gap; multi-`<Track>` continuity is resolved deterministically. Files with multiple GPS activities are rejected as ambiguous. Partial missing timestamps are interpolated. |
| FIT | Common running activities | Decodes CRC-validated file-ID, record, event, lap, session, activity, and device-info messages in source order. Lap messages from the selected session become `RecordedLap` values with FIT `lap_trigger` mapping. Compressed timestamps, enhanced altitude/speed, and timer-derived route gaps are supported. Lap messages never create route segments. A container with two or more session messages opens the multi-session review flow described below. |
| HealthKit | Not implemented | Research-only future phase. Requires entitlements and a separate privacy review. |

## Multi-session FIT import

**Import File…** is the only entry point. A user never has to know in advance
whether a `.fit` file holds one run or many.

### Direct versus review routing

| Session messages in the container | Behaviour |
| --- | --- |
| 0 (legacy sessionless file) | Direct single-workout import; no review sheet |
| 1 | Direct single-workout import; no review sheet |
| 2 or more | **Import FIT Sessions** review sheet |

GPX, TCX, and JSON never reach the FIT scanner. The scan runs off the main
actor and parses the container once; the review sheet holds only lightweight
session descriptors, never decoded FIT messages.

### Candidate statuses

| Status | Meaning | Selectable |
| --- | --- | --- |
| Ready | Attributable running session with GPS | Yes (default) |
| Already imported | A workout with this session identity exists | No |
| Unsupported sport | A known non-running FIT sport | No |
| No GPS route | No attributable record carries usable coordinates | No |
| Missing session boundaries | Start or end could not be resolved | No |
| Ambiguous session data | Time range materially overlaps another session | No |
| Exceeds resource limit | Container exceeds record/event/lap limits | No |
| Could not parse | The session failed during import | No |

Only **Ready** is selected by default. Every other session stays visible for
transparency, with a text explanation rather than colour alone.

### Sport policy

`FITSportPolicy` is the single classifier used by both scan and import.
`FITSport.running` is supported. A missing or unrecognised sport value is
treated as running and carries an explicit warning. Every other known profile
sport — **including walking and hiking** — is unsupported. This intentionally
differs from `StravaActivityTypePolicy`, whose walk/hike acceptance applies to
Strava bulk-export metadata rows rather than to FIT session messages.

### Boundary and overlap policy

- Start prefers a valid `start_time`, then a valid end timestamp minus a valid
  `total_elapsed_time`.
- End prefers the session's own `timestamp`, then the immediately following
  session's resolved start as a bounded conservative fallback (exclusive).
- A session with no reliable start, or no reliable end and no next boundary, is
  not importable. The first or last record of the whole file is never used as a
  silent fallback in a multi-session container.
- Session start is inclusive. A session end is inclusive **unless** a later
  session starts on that exact timestamp, in which case the boundary sample
  belongs to the **later** session. One record therefore never contributes to
  two workouts.
- Materially overlapping ranges mark every affected session ambiguous. Records
  inside an overlap are not assigned by guesswork and the sessions are not
  selected by default.

### Record, event, and lap attribution

- Records, timer events, and laps without a usable timestamp are excluded in
  multi-session mode; they are never guessed into a session.
- Timer events remain authoritative for pause/resume route segmentation and are
  scoped per session. An event in one session never splits another session's
  route, and a session boundary is not treated as a pause.
- Laps are associated by `first_lap_index` + `number_of_laps` using the lower
  12 bits of `message_index`, then by lap timestamp range, then not at all.
  Conflicting index claims are dropped for every claimant. A lap array index is
  claimed at most once across the whole container.
- Malformed laps inside a session that declares them are retained provisionally
  so `RecordedLapAnalyzer` can diagnose them; one malformed lap does not reject
  an otherwise valid session.
- Source elapsed/timer warnings compare each workout only against its own
  session totals, never against file-wide totals or a sibling session.

### Complexity

Session preparation is `O(s log s)`. Record, event, and lap attribution are
each `O(n + s)` after preparation, rising to `O(n log n)` only when the
container's source order is not chronological. Buckets for every session are
filled in one source-order pass, so no `records × sessions` scan exists. The
container is parsed at most once per phase; each selected session is decoded
from that one `FITDecodedFile` rather than by re-reading the binary.

### Transaction semantics

Selected sessions are parsed individually and staged; a per-session failure
does not prevent valid siblings from being staged. All staged workouts commit
together in one manifest update. Zero staged workouts roll back. A commit
failure imports none of them and the report says so — a staged session whose
commit failed is reported as **Not saved**, never as imported. After a
successful commit the newest imported session by start date is selected, with
FIT source order as the deterministic tie breaker.

### Identity and duplicates

Multi-session imports record `WorkoutImportProvider.fitMultiSessionFile` and an
optional `sourceContainerSHA256` (lowercase hex SHA-256 of the whole original
container). `providerActivityID` is `fit-session-v1:<digest>` over the container
hash, source ordinal, raw start and end timestamps, sport, sub-sport, message
index, first lap index, and lap count — no locale-formatted dates, absolute
paths, or account identifiers.

An exact duplicate requires provider `.fitMultiSessionFile` **and** a matching
`providerActivityID`. A shared container hash alone never marks siblings
duplicate, and `contentSHA256` stays `nil` for these workouts so sibling
sessions cannot look identical. Renaming the file does not change identity.
Editing the container produces new identities; RunPlay Studio does not silently
merge a modified file with previous imports.

### Resource limits and cancellation

`FITMultiSessionImportPolicy` centralises the limits: the existing 100 MB FIT
container ceiling, at most 256 scanned sessions, at most 100 selected sessions
per transaction, and record/event/lap ceilings. Only local `file:` URLs are
read — never HTTP, remote schemes, string paths, or directories — and
security-scoped access is held for the whole scan → review → import lifetime,
then released on dismissal. Cancellation is checked before the file read,
during parsing, during attribution, between candidate imports, before staging,
and before commit; it rolls staging back and returns a structured cancelled
report rather than a parse error.

### Accessibility

The review sheet supports full keyboard access with default and cancel key
actions, VoiceOver labels and values for every row and control, a live selected
count, and status conveyed as text rather than colour alone. It participates in
the existing modal command-blocking architecture, so background replay, delete,
and import commands stay inert while it is visible.

### Known limitation: nested batch review

A Strava bulk-export archive entry that itself contains several running
sessions stays fail-safe. Archive activity entries continue to use
`WorkoutImporterFactory.importWorkout(from: WorkoutImportInput)`, which rejects
an ambiguous multi-session container and reports that entry in the archive
report. Nested batch review inside archive import is out of scope.

## Current Limitations

- Import is file-based and local-only.
- FIT support targets common running activity files, not the full FIT profile. It was implemented against Garmin FIT SDK Profile 21.205.0.
- FIT developer metrics, component accumulation, unsupported subfields, and course/workout files remain unsupported.
- All formats use route-derived clocks: elapsed is final timestamp minus initial timestamp, falling back to a normalized per-point elapsed series only when timestamps do not span. Active sums positive adjacent deltas within a continuous route segment; the fallback treats all elapsed time as active because it cannot infer pauses. Paused is elapsed minus active. Moving time is not estimated.
- Every format passes through the same local, platform-neutral
  `RouteQualityProcessor`. It validates fields, removes only strongly supported
  isolated coordinate teleports, introduces a segment boundary for a supported
  coherent relocation, normalizes distance, builds one corrected elevation
  profile, and retains non-fatal diagnostics and warnings. It does not call a
  map-matching, routing, elevation, geocoding, cloud, or AI service.
- Explicit source track and timer boundaries remain authoritative. An inferred
  boundary requires a geographic relocation plus speed/interval evidence and a
  coherent following cluster. Long-interval evidence must also be at least
  three times the resumed sampling cadence, so a uniformly sparse route does
  not become a false gap; a long timestamp interval alone never creates a
  segment. No distance, derived speed/pace, smoothing, elevation delta,
  interpolation, or map geometry crosses an explicit or inferred boundary.
- Distance precedence is deliberate. GPX derives distance from retained
  coordinates. TCX and JSON preserve a complete finite non-negative monotonic
  supplied series; otherwise they use retained coordinate geometry. FIT makes
  that supplied-versus-derived decision per segment. Preserved device distance
  is rebased at compact segment boundaries and never decreases. The source and
  per-segment provenance are stored for deterministic migration.
- Source speed is optional evidence, never the sole coordinate-outlier test.
  Non-finite, negative, implausible, or grossly geometry-inconsistent speed is
  ignored so valid normalized distance and time can derive speed and pace. A
  recorded zero is likewise treated as missing when normalized movement exceeds
  1 m/s. Conversely, a positive source speed above 1 m/s is treated as stale
  when normalized geometry is stationary; legitimate stationary and sprint
  values remain supported.
- `RoutePoint.altitudeMeters` remains finite source altitude. Corrected
  presentation and analysis use an aligned `ElevationProfile` that rejects a
  locally unsupported interior or one-sided endpoint spike, or an extreme,
  tightly bounded two-sample interior excursion. Rejection uses travelled
  normalized distance so a switchback is not mistaken for a short spike. The
  profile smooths with a 15 m distance radius,
  preserves missing spans and segment boundaries, and calculates gain/loss with
  a 3 m trend-reversal deadband. Missing or sparse altitude is not converted to
  a fake zero-elevation route.
- FIT timer start/stop events separate route segments without adding geographic distance across a pause. Supplied FIT distance is rebased per complete segment; segments with missing or invalid distance use their coordinates instead. Route-point elapsed timestamps remain elapsed time.
- FIT selected-session elapsed/timer totals validate the route-derived clocks but never blindly replace them. Material mismatches (more than five seconds or two percent) produce import warnings.
- FIT and TCX **recorded laps** are preserved separately from calculated kilometre splits. Canonical lap metrics are always route-derived; source-reported lap totals are retained for validation. Material aggregated mismatches produce diagnostics or a non-fatal warning rather than one banner per minor difference.
- Malformed optional FIT/TCX lap messages or JSON recorded-lap elements do not invalidate an otherwise usable route. They are skipped with aggregated diagnostics; decoded lap metrics are revalidated as finite, non-negative, and within the shared HR/cadence ranges.
- TCX seamless manual/auto laps remain in one route segment. Multiple tracks use `TCXRouteContinuityResolver` (time/distance thresholds) so genuine pauses stay gaps while continuous tracks do not invent a pause.
- TCX `TriggerMethod` values map to documented triggers (`Manual`, `Distance`, `Time`, `Location`); unknown text is retained as unknown rather than guessed. FIT `lap_trigger` maps official profile codes; unknown codes keep the raw value.
- Old persisted FIT/TCX library snapshots that discarded source laps stay empty until the original file is reimported. GPX never invents laps.
- FIT parsing checks cancellation every 1,000 decoded messages and limits a file to 100 MB, 256 definition messages, 64 developer fields per definition, and 1,000,000 decoded messages.
- FIT signed coordinate decoding uses bit-pattern semantics for western and
  southern hemisphere coordinates.
- Quality diagnostics count invalid coordinates, discarded isolated coordinate
  points, inferred route gaps, discarded altitude samples, and invalid source
  speeds. Importers exclude invalid coordinates before timestamp resolution but
  pass their counts into the shared processor so those diagnostics are not
  lost. Retained warnings describe only meaningful recovery events; ordinary
  elevation smoothing is silent and successful recovery is not a blocking
  import error.
- Snapshots version route normalization separately from derived analysis. A
  legacy snapshot is decoded, normalized when required, analysed from one
  shared `WorkoutAnalysisContext`, and atomically rewritten. Identity, metadata,
  source, retained point IDs, library order, and selection remain
  stable. A failed upgrade write keeps the workout usable and the original
  snapshot retryable; current snapshots are not repeatedly rewritten.
- Route-quality stages use bounded sorting, linear timestamp-run resolution,
  default-policy bounded neighbourhood checks, linear scans, and rolling
  distance windows. Distance-stepped derived consumers use a fixed evaluation
  budget. Long interactive imports and derived-analysis loops check cooperative
  cancellation; `CancellationError` propagates without becoming a parsing
  error, analysis is assigned atomically, and persistence does not begin after
  cancellation.
- Malformed or unsupported files should fail with an import error instead of
  partial cloud recovery or background retry.
- Imported workouts are stored locally in the app's `Application Support/RunPlayStudio/` directory and persist across app relaunches. Normalization changes only RunPlay Studio's local snapshot; the original imported file is not modified.

## Fixtures

- `RunPlayStudio/Resources/sample_run.json`
- `RunPlayStudio/Resources/fixtures/realistic_5k_run.gpx`
- `RunPlayStudio/Resources/fixtures/sample-run.tcx`

Synthetic fixtures must not include private real workout data or personally
identifying routes.


## Strava Bulk Export Archives

RunPlay Studio can import **running activities** from a **local** Strava bulk-export
ZIP. There is **no** Strava login, OAuth, API call, or network access.

### How to get a Strava export

1. In Strava (web): **Settings → My Account → Download or Delete Your Account**.
2. Request a download of your archive and wait for Strava’s email.
3. Save the `.zip` on your Mac.
4. In RunPlay Studio: **Import Strava Archive…** and select the ZIP.

### What is imported

| Item | Support |
| --- | --- |
| `.fit`, `.gpx`, `.tcx` activity files | Yes |
| `.fit.gz`, `.gpx.gz`, `.tcx.gz` (one GZIP layer) | Yes |
| Running / trail / virtual run (GPS required) | Yes (default selected) |
| Walk / hike with GPS | Yes when the route importer accepts them |
| Cycling, swim, ski, and other sports | Skipped (reported) |
| Photos, media, social, profile data | Ignored |
| Nested ZIP / password-protected entries | Rejected / skipped |
| Indoor treadmill without GPS | Not imported |

### Duplicate and conflict policy

- **Exact duplicate:** same provider activity ID **or** same content SHA-256 → skipped, not selected by default.
- **Provider conflict:** same activity ID, different content hash → not imported; delete the existing workout first to replace.
- Re-importing the same archive adds **zero** new workouts when sources are unchanged.

### Security and limits

- The archive is **not** fully extracted to a temporary folder.
- Paths are validated (no traversal, absolute paths, or special file types).
- Finite limits apply to archive size, entry count, compression ratio, and concurrency.
- Processing is local-only; staged snapshots live under the library `.staging/` directory and are cleaned up on cancel, failure, or startup recovery.

### Completion report

After import, counts cover imported, duplicates, unsupported sports/formats,
no-GPS, parse failures, unsafe entries, and provider conflicts.
