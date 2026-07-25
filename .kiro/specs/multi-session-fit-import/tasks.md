# Tasks — Multi-session FIT import

- [x] Core models: session descriptor, statuses, scan result, selection,
      report, resource policy, `ContentDigesting`
- [x] Centralised `FITSportPolicy` used by scan and import
- [x] `FITSessionAttribution`: boundary resolution + bounded record/event/lap
      attribution with overlap detection
- [x] `FITSessionIdentity`: versioned provider activity ID
- [x] Provenance: `.fitMultiSessionFile` + optional `sourceContainerSHA256`
- [x] `FITDecoder.decodeRawResult(decodedFile:sessionIndex:)` explicit
      decode-by-index; legacy selection becomes a wrapper
- [x] `FITImporter.buildSession(...)` canonical builder; single-session path
      delegates to it
- [x] `FITSessionImportService` actor implementing scan + batch import
- [x] Platform `CryptoKitContentDigest`
- [x] Studio `FITSessionImportSession`, `FITSessionImportView`, AppState
      routing, ContentView sheet, modal command blocking
- [x] Core tests: discovery, attribution, events, laps, workout construction,
      provenance, transaction, performance
- [x] Studio tests: AppState routing, single-session regression parity
- [x] Documentation + Kiro steering + roadmap correction
- [x] Packaged-app build/launch verification (Escape-to-cancel unconfirmed; see docs/manual-testing.md)
- [x] CI green on PR head (a2c0617: RunPlayCore Linux + macOS Full Stack)
