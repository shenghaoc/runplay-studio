# RunPlay Studio - Import Formats

RunPlay Studio imports workout files locally. Imported data stays on the Mac; the
app does not upload files, create accounts, call analytics, or use AI APIs.

## Supported Formats

| Format | Status | Notes |
| --- | --- | --- |
| JSON | Full support | Native fixture format with route points, metadata, biometrics (heart rate, cadence, running power, and running dynamics), optional recorded laps, versioned route normalization, and versioned derived analysis. Legacy snapshots are normalized before they are reanalysed. |
| GPX | Track support | Parses `trk/trkseg/trkpt` GPS trackpoints, time, elevation, heart rate, and cadence extensions. Each track segment remains disconnected; waypoints and routes are ignored. Standard GPX does **not** define device laps — `recordedLaps` stays empty and `<trkseg>` is never treated as a lap. At least one timestamp is required for elapsed/active pace analysis; partial missing timestamps are interpolated. |
| TCX | Track support | Parses one GPS-bearing activity's laps (including summary fields and `TriggerMethod`), tracks, trackpoints, distance, elevation, heart rate, and cadence. A `<Lap>` boundary alone does **not** create a route gap; multi-`<Track>` continuity is resolved deterministically. Files with multiple GPS activities are rejected as ambiguous. Partial missing timestamps are interpolated. |
| FIT | Common running activities | Decodes CRC-validated file-ID, record, event, lap, session, activity, device-info, field_description (206), and developer_data_id (207) messages in source order. Lap messages from the selected session become `RecordedLap` values with FIT `lap_trigger` mapping. Compressed timestamps, enhanced altitude/speed, timer-derived route gaps, native record power and running dynamics, and developer fields (running power and dynamics) are supported; see "FIT developer data" below. Lap messages never create route segments. A container with two or more session messages opens the multi-session review flow described below. Importing real device activity files landed in #143 — earlier releases rejected every genuine file at the header. |
| HealthKit | Not implemented | Research-only future phase. Requires entitlements and a separate privacy review. |

## Workout size limits

Every format shares one set of product limits, defined once in
`WorkoutImportResourceLimits` and applied by each importer and by
`RouteQualityProcessor`:

| Limit | Value | Applied to |
| --- | --- | --- |
| Route points per workout | 1,000,000 | Total `<trkpt>` in a GPX file; trackpoints in the selected TCX activity; decoded `routePoints` in a JSON file; route points in each resulting FIT session. Archive entries inherit their format importer's limit. |
| Source payload | 100 MB | Every activity file, read through a bounded reader that stops at one byte past the limit rather than trusting file metadata. Archive entries keep their own smaller ceilings (50 MB compressed, 100 MB uncompressed). |

One million route points is roughly 278 hours of continuous one-second
recording, well beyond any single run.

Behaviour when a limit is exceeded:

- The whole workout is rejected. RunPlay Studio never truncates or partially
  imports an oversized route, because a silently shortened workout is worse
  than a refused one.
- GPX and TCX stop parsing at the first point past the limit, so an oversized
  route is never fully constructed.
- The error names the limit and states that the workout was not imported.
- In batch or archive import only that candidate fails; the rest of the
  transaction is unaffected.
- Existing persisted workouts above the limit are never deleted or rewritten.
  They stay visible with the usual route-quality upgrade warning.

The C++ engine carries a separate internal ceiling of 1,250,000 samples
(`max_route_input_samples`). That is a safety margin 25% above the product
limit, not a second product limit — a route the app accepts can never be
rejected at the engine boundary.

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
- End prefers the session's own `timestamp` when it is strictly after the
  start, then `start_time + total_elapsed_time` when the declared end is
  missing or degenerate (real devices exist that write
  `session.timestamp == session.start_time` and carry the duration only in
  `total_elapsed_time`; taken literally such a session collapses to a
  single-point window), then the **next session in FIT source order** (not
  time-sorted) when that next session's resolved start is ≥ this session's
  start — used as a bounded exclusive fallback.
- A session with no reliable start, or no reliable end and no next boundary, is
  not importable. The first or last record of the whole file is never used as a
  silent fallback in a multi-session container.
- Session start is inclusive. A session end is inclusive **unless** a later
  session starts on that exact timestamp, in which case the boundary sample
  belongs to the **later** session. One record therefore never contributes to
  two workouts.
- Materially overlapping ranges mark every affected session ambiguous. Records
  inside an overlap are not assigned by guesswork and the sessions are not
  selected by default. Lap index metadata never resolves time-range overlap.
- The GPS-bearing-session containment check uses the derived end, never the
  literal `timestamp`, so a degenerate session whose first GPS fix arrives
  after its start is still selected instead of silently falling back to the
  whole-file route.

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
- A lap's end prefers its `timestamp` when that is strictly after the lap's
  `start_time`, then `start_time + total_elapsed_time` — the same degenerate
  device shape as sessions writes lap end timestamps at or before the lap's own
  start. A missing end still falls back to the next lap's start, then the
  session/route end.
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
hash, source ordinal, raw start and end timestamps, sport, sub-sport, first lap
index, and lap count — no locale-formatted dates, absolute paths, or account
identifiers. Session `message_index` is not part of the identity today (the
decoder does not parse it on session messages); adding it later requires a
`fit-session-v*` version bump.

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

The review sheet wires default and cancel key actions (same idiom as the Strava
archive sheet), VoiceOver labels and values for every row and control, a live
selected count, and status conveyed as text rather than colour alone. It
participates in the existing modal command-blocking architecture, so background
replay, delete, and import commands stay inert while it is visible.

**Verification note:** The packaged app has been checked with Return-to-import
and Escape-to-cancel. Its accessibility tree exposes the summary, every row's
name/sport/timing/counts/status, selection state, and every actionable control.
A spoken VoiceOver pass remains part of the broader release checklist; see
[manual-testing.md](manual-testing.md).

### Known limitation: nested batch review

A Strava bulk-export archive entry that itself contains several running
sessions stays fail-safe. Archive activity entries continue to use
`WorkoutImporterFactory.importWorkout(from: WorkoutImportInput)`, which rejects
an ambiguous multi-session container and reports that entry in the archive
report. Nested batch review inside archive import is out of scope.

## Current Limitations

- Import is file-based and local-only.
- FIT support targets common running activity files, not the full FIT profile. It was implemented against Garmin FIT SDK Profile 21.205.0.
- FIT developer fields are decoded (see "FIT developer data"), but component accumulation, subfield expansion, and course/workout files remain unsupported. Course and workout FIT files remain unsupported.
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
- JSON route points carry `powerWatts`, `groundContactTimeMilliseconds`, `verticalOscillationMillimeters`, `verticalRatioPercent`, `stanceTimeBalancePercent`, and `stepLengthMeters` under the same keys `RoutePoint` encodes, so an exported or persisted workout re-imports with power and dynamics intact. A value outside the shared `MetricValidation` range for its metric (for example negative power, or power above 5,000 W) is dropped from that point at import; other fields on the point and other points are unaffected, and no import warning is raised. JSON has no NaN or infinity literal, so a non-representable number rejects the file, as it does for heart rate. Heart rate and cadence are unchanged: they are retained as supplied and range-filtered by each consumer.
- TCX seamless manual/auto laps remain in one route segment. Multiple tracks use `TCXRouteContinuityResolver` (time/distance thresholds) so genuine pauses stay gaps while continuous tracks do not invent a pause.
- TCX `TriggerMethod` values map to documented triggers (`Manual`, `Distance`, `Time`, `Location`); unknown text is retained as unknown rather than guessed. FIT `lap_trigger` maps official profile codes; unknown codes keep the raw value.
- Old persisted FIT/TCX library snapshots that discarded source laps stay empty until the original file is reimported. GPX never invents laps.
- FIT parsing checks cancellation every 1,000 decoded messages and limits a file to 100 MB, 256 definition messages, 64 developer fields per definition, 256 retained field_description messages, 2,000,000 retained developer field values, and 1,000,000 decoded messages. The 100 MB ceiling and the 1,000,000 route-point limit are the shared values in `WorkoutImportResourceLimits`; the per-session route-point limit is enforced explicitly rather than inferred from the decoded-message ceiling.
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

## FIT developer data

FIT developer data fields let a device or Connect IQ application attach custom
metrics to record messages. RunPlay Studio decodes them as follows.

### Decoding

- `field_description` (206) and `developer_data_id` (207) messages are parsed
  with their official profile field layouts. Record developer field payloads
  are captured raw during parsing and resolved once against the file-wide
  description table, so descriptions that appear **after** the records using
  them (out-of-order files) resolve identically.
- Values convert with the FIT protocol formula
  `physical = raw / scale - offset` (defaults scale 1, offset 0). Base-type
  invalid sentinels (0xFF…, 0x7FFF for signed, NaN for floats, 0 for z-types)
  are treated as missing, never as real values.
- **The sign is unanimous** across the official Garmin SDKs — offset is
  subtracted, and no binding adds it. C++ SDK `src/fit_field_base.cpp:440`:
  `return float64Value / GetScale(subFieldIndex) - GetOffset(subFieldIndex);`
  (inverse encode at `:974`: `(value + GetOffset(...)) * GetScale(...)`).
  Swift SDK `Sources/FITSwiftSDK/FieldBase.swift:99`:
  `value = Float64(fitValue: value) / scale - offset`. This matches the
  convention the importer already applies to profile fields —
  `FITParser.scaledAltitudeToMeters` is `(raw / 5.0) - 500.0` for the
  profile's altitude scale 5 / offset 500. The rejected alternative,
  `raw / scale + offset`, is implemented by no official binding and would
  decode a non-zero-offset field wrong by exactly `2 × offset`.
- **The SDKs disagree on whether developer fields are scaled at all**, and
  that disagreement is reported rather than resolved:
  - The **C++ SDK declines**. `src/fit_developer_field.cpp:100-110` hard-codes
    `DeveloperField::GetScale()` to `1.0` and `GetOffset()` to `0`, commented
    "Developer fields do not currently support scale/offset" — developer
    values are returned raw.
  - The **Swift SDK applies**. `Sources/FITSwiftSDK/DeveloperField.swift:54-60`
    returns `fieldDescriptionMesg?.getScale() ?? 1` and `...getOffset() ?? 0`,
    feeding the description's values into the subtract above.
  - The **C SDK abstains**: it decodes no developer fields at all.

  This importer applies the conversion, matching the Swift SDK as the binding
  closest to RunPlayCore's decoding. Because the choice is contested, it is
  not allowed to be silent: see the diagnostic below. Pinned by
  `testDeveloperFieldOffsetIsSubtractedNotAdded`.
- A non-default developer scale or offset is rare — nearly every field
  ships scale 1 / offset 0 — and those are the only cases where either the
  sign or the apply/don't-apply choice is observable. Any developer field
  declaring scale ≠ 1 or offset ≠ 0 is therefore flagged in the workout's
  developer-field notes, so the first real file carrying one makes the
  assumption visible instead of quietly decoding wrong.
- The `field_description` (206) and `developer_data_id` (207) field layouts
  and the `fit_base_unit` enum are verified against the official C++ and
  Swift SDK Profile sources (Profile 21.214.0). `fit_base_unit` is
  `other = 0`, `kilogram = 1`, `pound = 2`, `invalid = 0xFFFF`.
- Units come from the description's `units` string when populated; otherwise
  the `fit_base_unit_id` resolves through the verified enum (`1` → `kg`,
  `2` → `lb`). `other = 0` names no unit and resolves to nothing; an id
  outside the enum is retained raw (`fit_base_unit:<id>`) so a future profile
  addition stays visible instead of being silently dropped.

### Recognition

Recognition is **name-based**, with the application identity retained as
provenance (tiebreak, not gate): an unrecognized application whose field
names are sane is still recognized. Names are matched case-insensitively
after trimming and collapsing all whitespace. Recognized names cover
Stryd, Garmin Connect IQ running power, and Garmin/COROS-style running
dynamics: `power`, `form power`, `leg spring stiffness`, `ground time` /
`ground contact time` / `stance time`, `vertical oscillation`,
`vertical ratio`, `stance time balance`, and `step length` (common
spellings and `lss`/`gct` abbreviations included). Power, ground contact
time, vertical oscillation, vertical ratio, stance time balance, and
step length map onto route-point fields; form power and leg spring
stiffness are recognized but have no per-point home. Native record power
(field 7) is also decoded; when both a developer field and the native
field supply power for the same point, the developer field wins and the
conflict is reported.

The registry remains **unverified against real vendor developer-field
data**: neither real file available to date carries developer fields, so
every recognized spelling comes from vendor documentation, not from a
decoded device file. A real Stryd or Connect IQ file whose fields land
on the right route-point metrics — with values matching the vendor's own
app — is what would verify it; a miss is not silent, because the field
is still retained with its raw identity, name, and statistics.

### Native running dynamics

Garmin watches write running dynamics as **native record fields**, not
developer fields — the common case for running dynamics data in the
wild. Record fields 39 (vertical oscillation, scale 10, mm), 41 (stance
time, scale 10, ms), 83 (vertical ratio, scale 100, percent), 84 (stance
time balance, scale 100, percent), and 85 (step length, scale 10, mm)
decode onto the same route-point fields the developer path populates;
field 40 (stance time percent) has no route-point home and is not
mapped further. Scales and units are confirmed against the official
Garmin SDK Profile (21.214.0), which agrees across its C++, Swift, and
Objective-C bindings (`src/fit_profile.cpp:1079-1081,1111-1113` in the
C++ SDK, `RecordMesg.swift:1158-1160,1190-1192` in the Swift SDK);
invalid sentinel `0xFFFF` decodes as absent. Precedence mirrors native
power: a recognized developer value wins per metric, and the native
field fills only what the developer path left absent on that point. The
persisted summary distinguishes the origins
(`dynamicsSourceIsNativeRecordField`, `powerSourceIsNativeRecordField`)
so a native-only file — the most common hardware — reports its source
as the watch itself.

### Retention and diagnostics

- Unrecognised fields are **not** dropped and **not** persisted per point.
  The snapshot retains, per field: the developer application identity, field
  name, unit, base type, scale/offset, sample count, route-point coverage,
  and minimum/maximum/mean — enough to answer "what is my watch recording
  that RunPlay Studio does not understand?" at most 16 fields; further fields
  are counted in a truncation note. The source file remains the record;
  reimporting it is the path to anything richer.
- Diagnostics notes report values skipped for missing field descriptions,
  invalid sentinels, multi-source power conflicts, parser retention-limit
  drops, and fields declaring accumulation. Fields that declare accumulation
  are decoded as instantaneous samples (accumulation math is out of scope and
  stated as such).
- Old snapshots pre-dating developer-data decode stay valid and simply carry
  no developer fields; reimporting the original file adds them. No snapshot
  version changes.

## Recorded UTC offset

Text formats that carry an explicit zone designator record it on
`WorkoutMetadata.recordedUTCOffsetSeconds`: GPX and TCX capture the literal
offset of the first timestamp text/attribute that both parses as an instant
and carries a designator (`Z` is `0`, `+09:00` is `32_400`), and the JSON
importer retains either an explicit metadata value or the first route-point
timestamp designator. A designator is only read after the `T` time separator,
so a date-only or otherwise unparseable timestamp contributes nothing rather
than offering its date separator as a sign. FIT logs UTC instants only and
records no offset. Calendar features (Trends bucketing) use the recorded
local date; workouts without a recorded offset fall back to the system zone.

## Workout size and payload limits

`WorkoutImportResourceLimits` defines the product limits once, and every
importer plus the `RouteQualityProcessor` preflight reads them from there:

| Limit | Constant | Value |
| --- | --- | --- |
| Route points per resulting workout | `maxRoutePointCount` | 1,000,000 |
| Source payload | `maxSourceFileBytes` | 100 MiB (`100 * 1024 * 1024`) |

The C++ engine's `max_route_input_samples` is an internal safety ceiling 25%
above the route-point limit, so a route the app accepts can never be rejected
by the engine. Raising the product limit requires raising that ceiling to
preserve the margin; a parity test enforces the relationship. Do not add a
second copy of either number to an importer.
