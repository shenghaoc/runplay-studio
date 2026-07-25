# Tasks — Multi-session FIT import

- [ ] Core models: session descriptor, statuses, scan result, selection,
      report, resource policy, `ContentDigesting`
- [ ] Centralised `FITSportPolicy` used by scan and import
- [ ] `FITSessionAttribution`: boundary resolution + bounded record/event/lap
      attribution with overlap detection
- [ ] `FITSessionIdentity`: versioned provider activity ID
- [ ] Provenance: `.fitMultiSessionFile` + optional `sourceContainerSHA256`
- [ ] `FITDecoder.decodeRawResult(decodedFile:sessionIndex:)` explicit
      decode-by-index; legacy selection becomes a wrapper
- [ ] `FITImporter.buildSession(...)` canonical builder; single-session path
      delegates to it
- [ ] `FITSessionImportService` actor implementing scan + batch import
- [ ] Platform `CryptoKitContentDigest`
- [ ] Studio `FITSessionImportSession`, `FITSessionImportView`, AppState
      routing, ContentView sheet, modal command blocking
- [ ] Core tests: discovery, attribution, events, laps, workout construction,
      provenance, transaction, performance
- [ ] Studio tests: AppState routing, single-session regression parity
- [ ] Documentation + Kiro steering + roadmap correction
- [ ] Packaged-app build/launch verification
- [ ] CI green on PR head
