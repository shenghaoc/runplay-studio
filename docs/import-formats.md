# RunPlay Studio - Import Formats

RunPlay Studio imports workout files locally. Imported data stays on the Mac; the
app does not upload files, create accounts, call analytics, or use AI APIs.

## Supported Formats

| Format | Status | Notes |
| --- | --- | --- |
| JSON | Full support | Native fixture format with route points, metadata, biometrics, and derived analysis. |
| GPX | Track support | Parses GPS trackpoints, time, elevation, heart rate, and cadence extensions where present. At least one timestamp is required for pace/duration analysis; partial missing timestamps are interpolated. |
| TCX | Track support | Parses Training Center XML activities, laps, trackpoints, distance, elevation, heart rate, and cadence. First nonzero distance values are rebased to route start; partial missing timestamps are interpolated. |
| FIT | Basic support | Parses common activity records for GPS, altitude, speed, heart rate, and cadence. Requires at least one timestamp. CRC-16 validation (header and file) rejects corrupted files with a descriptive error. Compressed timestamp headers fail with a controlled unsupported-data error. |
| HealthKit | Not implemented | Research-only future phase. Requires entitlements and a separate privacy review. |

## Current Limitations

- Import is file-based and local-only.
- FIT support targets basic activity files, not the full FIT profile.
- FIT signed coordinate decoding uses bit-pattern semantics for western and
  southern hemisphere coordinates.
- Import normalization filters invalid coordinates and keeps elapsed time and
  cumulative distance monotonic before analysis.
- Malformed or unsupported files should fail with an import error instead of
  partial cloud recovery or background retry.
- Imported workouts are held in app memory for the current session.

## Fixtures

- `RunPlayStudio/Resources/sample_run.json`
- `RunPlayStudio/Resources/fixtures/realistic_5k_run.gpx`
- `RunPlayStudio/Resources/fixtures/sample-run.tcx`

Synthetic fixtures must not include private real workout data or personally
identifying routes.
