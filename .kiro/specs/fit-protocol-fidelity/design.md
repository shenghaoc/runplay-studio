# Design Document

## Overview

The FIT feature is split into two `RunPlayCore` stages. `FITParser` reads the
binary stream and emits typed, source-ordered standard messages. `FITDecoder`
then selects one running session, filters records and timer events to that
session, and creates `RoutePoint` values that preserve pause boundaries.

No new SwiftUI control is introduced. The existing file importer already sends
`.fit` URLs through the asynchronous import service, so the improvement reaches
the same native import flow as GPX, TCX, and JSON.

## Components

### Binary parser

- `FITBinaryReader` consumes FIT base types and complete field payloads with
  the definition's endianness and invalid sentinels.
- `FITParser` validates headers, CRCs, reserved values, definitions, resource
  limits, and compressed-timestamp constraints.
- `FITDecodedFile` owns typed arrays plus `FITOrderedMessage`, preserving the
  order of supported file-ID, record, event, lap, session, activity, and
  device-info messages.

### Activity interpretation

- `FITDecoder` selects only an unambiguous GPS-bearing `.running` session.
- Session time association uses `start_time` or derives a start from the end
  timestamp and `total_elapsed_time`; unassociable multi-session files fail.
- Timer events create `routeSegmentIndex` boundaries. `RoutePointSanitizer`
  rebases supplied distance independently for valid segments and falls back to
  coordinates for invalid ones.
- `FITImporter` creates metadata from the selected session, leaves unknown
  device names unset, runs analysis, and returns Core's normal `RunWorkout`.

## Boundaries and limitations

- `RunPlayCore` contains all FIT parsing and interpretation. Platform and UI
  targets do not own FIT protocol logic.
- The parser supports common running activities, not every FIT profile feature.
  Developer metrics, component accumulation, unsupported subfields, course and
  workout files, and batch multi-session import remain unsupported.
- UI validation is limited to the existing import plumbing and package launch;
  detailed FIT GUI scenarios remain manual checklist items rather than claims
  of an unperformed visual pass.

## Verification Strategy

- Core parser tests use synthetic binary fixtures for CRCs, base types,
  compressed records, activity/session mapping, malformed definitions,
  cancellation, and bounded decoding.
- Decoder and sanitizer tests prove session rejection, timer segmentation, and
  per-segment supplied-distance fallback.
- Full SwiftPM, Xcode package-scheme tests, and `build_and_run.sh --verify`
  confirm the Core change remains integrated with the macOS application.
