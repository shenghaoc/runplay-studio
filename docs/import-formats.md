# RunPlay Studio - Import Formats

RunPlay Studio imports workout files locally. Imported data stays on the Mac; the
app does not upload files, create accounts, call analytics, or use AI APIs.

## Supported Formats

| Format | Status | Notes |
| --- | --- | --- |
| JSON | Full support | Native fixture format with route points, metadata, biometrics, and derived analysis. |
| GPX | Full support | Parses GPS trackpoints, time, elevation, heart rate, and cadence extensions where present. |
| TCX | Full support | Parses Training Center XML activities, laps, trackpoints, distance, elevation, heart rate, and cadence. |
| FIT | Basic support | Parses common activity records for GPS, altitude, speed, heart rate, and cadence. CRC validation is not implemented. |
| HealthKit | Not implemented | Research-only future phase. Requires entitlements and a separate privacy review. |

## Current Limitations

- Import is file-based and local-only.
- FIT support targets basic activity files, not the full FIT profile.
- Malformed or unsupported files should fail with an import error instead of
  partial cloud recovery or background retry.
- Imported workouts are held in app memory for the current session.

## Fixtures

- `RunPlayStudio/Resources/sample_run.json`
- `RunPlayStudio/Resources/fixtures/realistic_5k_run.gpx`
- `RunPlayStudio/Resources/fixtures/sample-run.tcx`

Synthetic fixtures must not include private real workout data or personally
identifying routes.
