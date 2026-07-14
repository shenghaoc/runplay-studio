# RunPlay Studio - Import Formats

RunPlay Studio imports workout files locally. Imported data stays on the Mac; the
app does not upload files, create accounts, call analytics, or use AI APIs.

## Supported Formats

| Format | Status | Notes |
| --- | --- | --- |
| JSON | Full support | Native fixture format with route points, metadata, biometrics, versioned route normalization, and versioned derived analysis. Legacy snapshots are normalized before they are reanalysed. |
| GPX | Track support | Parses `trk/trkseg/trkpt` GPS trackpoints, time, elevation, heart rate, and cadence extensions. Each track segment remains disconnected; waypoints and routes are ignored. At least one timestamp is required for elapsed/active pace analysis; partial missing timestamps are interpolated. |
| TCX | Track support | Parses one GPS-bearing activity's laps, tracks, trackpoints, distance, elevation, heart rate, and cadence. Each track remains disconnected and is rebased independently; files with multiple GPS activities are rejected as ambiguous. Partial missing timestamps are interpolated. |
| FIT | Common running activities | Decodes CRC-validated file-ID, record, event, lap, session, activity, and device-info messages in source order. Compressed timestamps, enhanced altitude/speed, and timer-derived route gaps are supported. One unambiguous GPS-bearing running session is imported when session metadata exists; valid GPS records fall back to one legacy activity when it does not. |
| HealthKit | Not implemented | Research-only future phase. Requires entitlements and a separate privacy review. |

## Current Limitations

- Import is file-based and local-only.
- FIT support targets common running activity files, not the full FIT profile. It was implemented against Garmin FIT SDK Profile 21.205.0.
- FIT developer metrics, component accumulation, unsupported subfields, course/workout files, and batch multi-session import remain unsupported.
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
