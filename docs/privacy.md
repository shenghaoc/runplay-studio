# RunPlay Studio — Privacy Policy

## Local Workout Processing

RunPlay Studio processes all workout data locally on your Mac. No workout files, analysis results, or personal fitness data are transmitted to any external server, service, or API.

## MapKit / Apple Maps

The app uses Apple MapKit to display a 2D map view of your route. MapKit loads map tiles and map context from Apple map services over the network. **Map tile loading is the one network activity in the app** — it is handled entirely by Apple's MapKit framework and is subject to Apple's privacy policies. No workout data is included in map tile requests.

## No Cloud

There is no cloud sync, cloud storage, or cloud processing for workout data. All files remain on your local filesystem.

## No Analytics

RunPlay Studio does not collect usage analytics, event tracking, or behavioral data of any kind.

## No Telemetry

RunPlay Studio does not phone home, send crash reports automatically, or transmit any diagnostic data.

## No Account

There is no sign-up, login, user account, or authentication system. The app works entirely without identity.

## No AI API

RunPlay Studio does not connect to OpenAI, Anthropic, Google Gemini, or any other AI service. All workout analysis is local using Apple frameworks.

## Data Storage

- Workout data is stored in the format you import it (JSON, GPX, etc.)
- No database is used in the MVP
- Files are accessed via macOS file open dialogs
- No data is cached beyond what macOS provides

## Exports

All exports (JSON, CSV, PNG) are generated and saved locally. No export data is uploaded anywhere.

## Future Considerations

If cloud sync or HealthKit integration is added in the future:

- It will be opt-in only
- Privacy implications will be clearly documented
- Users will maintain full control of their data
