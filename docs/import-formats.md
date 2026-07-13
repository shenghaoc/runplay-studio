# RunPlay Studio - Import Formats

RunPlay Studio imports workout files locally. Imported data stays on the Mac; the
app does not upload files, create accounts, call analytics, or use AI APIs.

## Supported Formats

| Format | Status | Notes |
| --- | --- | --- |
| JSON | Full support | Native fixture format with route points, metadata, biometrics, and versioned derived analysis. Legacy snapshots are reanalysed from stored route points. |
| GPX | Track support | Parses `trk/trkseg/trkpt` GPS trackpoints, time, elevation, heart rate, and cadence extensions. Each track segment remains disconnected; waypoints and routes are ignored. At least one timestamp is required for elapsed/active pace analysis; partial missing timestamps are interpolated. |
| TCX | Track support | Parses one GPS-bearing activity's laps, tracks, trackpoints, distance, elevation, heart rate, and cadence. Each track remains disconnected and is rebased independently; files with multiple GPS activities are rejected as ambiguous. Partial missing timestamps are interpolated. |
| FIT | Common running activities | Decodes CRC-validated file-ID, record, event, lap, session, activity, and device-info messages in source order. Compressed timestamps, enhanced altitude/speed, and timer-derived route gaps are supported. One unambiguous GPS-bearing running session is imported when session metadata exists; valid GPS records fall back to one legacy activity when it does not. |
| HealthKit | Not implemented | Research-only future phase. Requires entitlements and a separate privacy review. |

## Current Limitations

- Import is file-based and local-only.
- FIT support targets common running activity files, not the full FIT profile. It was implemented against Garmin FIT SDK Profile 21.205.0.
- FIT developer metrics, component accumulation, unsupported subfields, course/workout files, and batch multi-session import remain unsupported.
- All formats use route-derived clocks: elapsed is final timestamp minus initial timestamp, falling back to a normalized per-point elapsed series only when timestamps do not span. Active sums positive adjacent deltas within a continuous route segment; the fallback treats all elapsed time as active because it cannot infer pauses. Paused is elapsed minus active. Moving time is not estimated.
- FIT timer start/stop events separate route segments without adding geographic distance across a pause. Supplied FIT distance is rebased per complete segment; segments with missing or invalid distance use their coordinates instead. Route-point elapsed timestamps remain elapsed time.
- FIT selected-session elapsed/timer totals validate the route-derived clocks but never blindly replace them. Material mismatches (more than five seconds or two percent) produce import warnings.
- FIT parsing checks cancellation every 1,000 decoded messages and limits a file to 100 MB, 256 definition messages, 64 developer fields per definition, and 1,000,000 decoded messages.
- FIT signed coordinate decoding uses bit-pattern semantics for western and
  southern hemisphere coordinates.
- Import normalization filters invalid coordinates, preserves source track
  boundaries, and keeps cumulative distance monotonic without adding distance
  across a recording gap. Analytics and rendering do not bridge those gaps.
- Malformed or unsupported files should fail with an import error instead of
  partial cloud recovery or background retry.
- Imported workouts are stored locally in the app's `Application Support/RunPlayStudio/` directory and persist across app relaunches. The original imported file is not modified.

## Fixtures

- `RunPlayStudio/Resources/sample_run.json`
- `RunPlayStudio/Resources/fixtures/realistic_5k_run.gpx`
- `RunPlayStudio/Resources/fixtures/sample-run.tcx`

Synthetic fixtures must not include private real workout data or personally
identifying routes.
