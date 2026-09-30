# Apple Health export import

RunPlay Studio supports running workouts from the iPhone Health app's
**Export All Health Data** archive. Use **File → Import Apple Health Export…**
and choose the intact local `export.zip`. Ordinary workout import and watch
folders do not identify Health ZIPs by sniffing their contents.

## Export from your iPhone

1. Open **Health**, select **Summary**, and tap your picture or initials.
2. Tap **Export All Health Data**, then choose a sharing method.
3. Transfer the resulting archive to your Mac, for example with AirDrop or
   Files. Keep it zipped and select it with the Apple Health import command.

These are Apple's [Health data export instructions](https://support.apple.com/guide/iphone/iph5ede58c3d/ios).
The archive includes more health history than RunPlay Studio imports; keep the
original private and retain it independently of the app's library.

## Scope and review

The reader streams `apple_health_export/export.xml`, finds running `Workout`
records, follows their `WorkoutRoute/FileReference` GPX references, and joins
**top-level heart-rate records by time overlap** with each workout window.
Running includes indoor and treadmill runs. Walking, hiking, cycling and other
activity identifiers are excluded before duplicate checking; the review and
final report state how many non-running workouts were skipped.

Review rows show the date, source distance when available, route reference,
heart-rate availability and duplicate status. A route indicator means the
export names a route file; the importer validates that file when importing.
Identical windows are **Duplicate**; partial overlaps are **Possible duplicate**.
Both flags start unchecked, whether the overlap is in this export or the
existing library. Check a flagged row only after reviewing it. Selected runs
are staged and saved in one transaction; cancelling or failing the commit
leaves the library unchanged. A later import skips exact library-window matches.

The export provides no workout UUID used by this importer. Its candidate
identity is derived locally from the workout window, activity identifier and
source ordinal; a shared route filename is never a workout identity.

## Routes, summaries and heart rate

Valid routed runs use the ordinary GPX analysis pipeline: distance, pace and
splits are route-derived, even if Health reports a different summary distance.
The summary records `.gpsDerived` provenance.

Each route is checked independently against its workout's absolute time window:

- A route already within the window **±60 seconds**, with actual overlap, is
  retained without changing its analysis.
- An early start or late end **at most five minutes** beyond either endpoint is
  trimmed to the inclusive ±60-second bounds, then analysed again from the
  trimmed GPS points. Recording gaps remain disconnected. At least two points
  must survive.
- No overlap, an overrun beyond five minutes, or too few retained points means
  the run imports without that route, counted as `routeWindowMismatch`.
- A missing, unreadable or rejected route file also permits a route-less import;
  it is reported separately from a time mismatch.

A run without a route retains source-reported distance when present, duration
from its workout window, joined HR and the recorded UTC offset. Its summary
records `.sourceReported` provenance. The app invents no route or kilometre
splits. Route-less runs offer summary metrics and a time-domain HR chart when
samples exist; the map shows an explicit no-GPS state and distance splits and
segments are unavailable. They participate in Trends and Training Load, and
longest-run records use summary distance. Heatmap, route grouping,
distance-window records, comparison and replay exclude them.

PNG export can produce a metrics-only card without a map; MP4 replay requires
a usable route and explains its absence. Library JSON snapshots retain the summary provenance.
HR has one source: route points or the standalone series, never both. Missing
HR is left missing. The recorded start offset is retained separately from the
UTC instant so Trends uses the workout's recorded local date.

## Report counters

| Counter | Meaning |
| --- | --- |
| Imported | Successful runs that did not need a referenced-route fallback; includes runs whose export never named a route. |
| Without a route | Successful imports whose referenced route was unavailable or mismatched; not every route-less run. |
| Route-window mismatch | Successful per-workout fallbacks because the named GPX did not fit the workout's time. The report says runs were imported without a map because the route file did not match the run's time. |
| Trimmed routes | Successful runs whose small route overrun was trimmed; separate from mismatches. |
| Already in your library | Exact window matches left unchanged at import time. |
| Could not be read | Selected workouts that could not be constructed. |
| Not saved | Staged workouts discarded after cancellation or commit failure; not successful imports. |
| Non-running workouts skipped | Parsed workouts excluded by activity identifier before candidate building. |
| Workouts the import cannot read | Workout records with missing or unreadable dates, never offered in review. |
| Unmatched route references | Export workout references naming GPX entries absent from the archive, including excluded activities. |

Scan diagnostics additionally count ignored nested non-HR `Record` elements
by type identifier (`ignoredNonHeartRateRecords`) and whether the HR ceiling
required a second pass. These are programmatic diagnostics, not extra saved
health metrics. Unsupported nested metrics are ignored; they are not reported
as lost heart rate. Only top-level HR records are joined in this version.

## Limits and refusals

`export.xml` has no individual-source payload cap: it is streamed from a
private extracted file. Extraction needs free space equal to the central
directory's declared uncompressed XML size. Actual bytes written may not exceed
that declaration. An oversized expansion is refused and the partial file is
removed. Individual GPX entries retain the **100 MiB** payload cap and each
resulting workout retains the **1,000,000-point** limit.

The current shared archive policy also limits the ZIP file to **2 GiB** and
its listing to **100,000 entries**. The whole-ZIP limit can reject a legitimate
large Health export; it is a known limitation, not a limit on streamed XML.
The HR buffer holds at most **2,000,000 samples**. Above that, parsing rereads the
XML and retains only HR overlapping workout windows; it refuses the import if
that filtered index still exceeds the ceiling.

The guarded DTD elider refuses entities, notations, fixed/default attributes or
other value-supplying declarations rather than silently discarding values.
External DTDs are not fetched.

**ZIP64 limitation:** pinned ZIPFoundation 0.9.20 cannot list a valid archive
whose first entry's local-header offset is stored as zero in a ZIP64 extra
field. Such an archive is refused as lacking `export.xml`; it is not imported
as an empty library. This does not affect every ZIP64 archive: generated tests
cover readable ZIP64 archives with data descriptors as well as the offset-zero
refusal. Changing the pin must recheck both cases.

## Local processing

Processing uses local files only: no HealthKit request, account, upload or
telemetry. The source archive is never changed. The temporary XML is in a
private user-cache directory and removed when the scan finishes, fails or is
cancelled; stale crash leftovers are cleaned on a later scan. Only selected
running workouts reach the library. See [privacy](privacy.md#apple-health-export-import)
and [private-data handling](private-data.md).
Direct HealthKit is outside the project's signing policy; see
[the decision record](healthkit-viability.md).
