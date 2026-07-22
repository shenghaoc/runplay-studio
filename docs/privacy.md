# RunPlay Studio — Privacy Policy

## Local Workout Processing

RunPlay Studio processes all workout data locally on your Mac. No workout files,
analysis results, or personal fitness data are transmitted to any external
server, service, or API.

## Data Storage

Imported workouts are stored locally in the app's
`Application Support/RunPlayStudio/` directory as complete normalized snapshots.
The original imported file is never modified. Deleting a workout in the app
removes only RunPlay Studio's stored copy — the original file remains wherever
you kept it.

No external database, cloud storage, or sync service is used. All data stays on
your filesystem under your control.

## MapKit / Apple Maps

The app uses a SwiftUI MapKit view with flat 2D and realistic-elevation 3D
presentations on the same map. MapKit loads map tiles and context from Apple
map services over the network. **Map loading is the one network activity in the
app** — it is handled entirely by Apple's MapKit framework and is subject to
Apple's privacy policies. Requests cover the map region derived from your route
coordinates, so the general area of your route is visible to Apple Maps. No
workout file data, metrics, heart rate, or account information is included in
map requests.

## Personal Heatmap

The Personal Heatmap workspace aggregates route coverage **locally** across the
workout library currently loaded in the app. Aggregation never uploads route
data, does not call geocoding or third-party heatmap services, and does not
persist a separate heatmap database. Results live in an in-memory cache for the
session and are recomputed when the library or filters change.

Apple Maps may still load basemap tiles for the heatmap’s geographic bounds under
the MapKit policy above. Workout-cell counts and intensity are computed only on
device from distinct-workout cell traversal, not from raw GPS sample density.

## No Cloud

There is no cloud sync, cloud storage, or cloud processing. All workout files
and analysis results remain on your local Mac.

## No Analytics

RunPlay Studio does not collect usage analytics, event tracking, or behavioral
data of any kind.

## No Telemetry

RunPlay Studio does not phone home, send crash reports automatically, or
transmit any diagnostic data.

## No Account

There is no sign-up, login, user account, or authentication system. The app
works entirely without identity.

## No AI API

RunPlay Studio does not connect to OpenAI, Anthropic, Google Gemini, or any
other AI service. All workout analysis is performed locally using Apple
frameworks.

## Exports

All exports (JSON, CSV, PNG) are generated and saved locally via the macOS save
panel. No export data is uploaded to a RunPlay Studio service or cloud backend.

### PNG summary card

- Output is an exact **1200×1600** pixel PNG with deterministic Light or Dark
  appearance (not ambient system appearance at render time).
- Metrics-only cards use only local analysis. No Screen Recording permission.
- Map-inclusive cards request **Apple Maps** basemap imagery through MapKit for
  the planned route region. Workout files, provider IDs, archive paths, and
  precise home-address text are not embedded; the PNG does not include GPS/EXIF
  location metadata. The privacy footer states that map imagery is provided
  through Apple Maps when a map was included.
- Do not claim that no network operation occurred when map imagery was requested.

## Private Workout Files

For manual testing or dogfooding with real workout data, keep private files in
gitignored local paths (`local-workouts/` or `private-workouts/`). Never commit
real workout data, screenshots of private routes, or exports derived from
personal activity files. See `docs/private-data.md` for the full policy.

## Future Considerations

If HealthKit integration is added in a future phase, it will require explicit
entitlements and a separate privacy review. Any such change will be opt-in and
clearly documented before shipping.


## Strava bulk-export import

Archive import reads a user-selected ZIP entirely on-device. The app does not
contact Strava, does not require an account, and does not upload the archive.
Import provenance stores provider activity IDs and content hashes only — never
absolute archive paths, email addresses, or profile identifiers. Photos and
social data inside the export are ignored.
