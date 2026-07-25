# Design — Multi-session FIT import

## Layering

```
RunPlayStudio   FITSessionImportSession (main actor) + FITSessionImportView
                AppState routing: Import File… → scan → direct or review
        │
RunPlayCore     FITSessionImportService (actor)
                  ├─ makeScanResult / FITSessionMessageIndex
                  ├─ FITSessionAttribution    (boundaries + bounded walk)
                  ├─ FITSessionIdentity       (versioned digest)
                  ├─ FITSportPolicy           (single classification)
                  └─ FITImporter.buildSession (canonical workout builder)
        │
RunPlayPlatform CryptoKitContentDigest (only the SHA-256 provider)
```

`RunPlayPlatform` gains **no** FIT semantics. It only supplies a
`ContentDigesting` conformance, because `RunPlayCore` must build on Linux where
CryptoKit is unavailable and the repository forbids hand-rolled hashes.

## Two protocols, two phases

```swift
public protocol FITFileScanning: Sendable {
    func scanFITFile(at:existingWorkouts:progress:) async throws -> FITSessionScanResult
}
public protocol FITSessionBatchImporting: Sendable {
    func importSessions(_:from:existingWorkouts:storeActor:progress:) async throws
        -> FITSessionBatchImportReport
}
```

`WorkoutImportServicing.importWorkout` is unchanged and still returns exactly
one `RunWorkout`. Multi-session FIT is an additional service, not a weakening
of the general import contract.

The scan phase parses the container once and releases it. The import phase
reopens and parses once more, then decodes every selected session from that one
`FITDecodedFile`. The review sheet never retains decoded FIT messages.

## Routing

`FITSessionScanResult.routing`:

| sessions in file | routing              | behaviour                          |
|------------------|----------------------|------------------------------------|
| 0                | `.direct`            | legacy fallback, direct import     |
| 1                | `.direct`            | existing single-session path       |
| ≥ 2              | `.review`            | Import FIT Sessions sheet          |

`AppState.importWorkout(from:)` sends only `.fit` URLs through the scanner.
Every other extension goes straight to `WorkoutImportServicing`.

## Canonical workout builder

`FITImporter.buildSession(index:sessionIndex:suggestedName:provenance:)` owns
session-scoped record decoding, timer-event segmentation, metadata, recorded
laps, normalisation, analysis, timing warnings, source-structure version, and
provenance. `FITImporter.importWorkout(data:suggestedName:)` resolves the
existing single-session selection policy and then calls the same builder, so
direct and batch import can never diverge.

`FITDecoder.decodeRawResult(index:sessionIndex:)` is the explicit decode-by-index
entry point. No global decoder selection state exists.

## Boundary and attribution

`FITSessionAttribution.prepare(sessions:)` resolves one `FITSessionRange` per
session, sorts a copy by `(start, upperExclusive, sourceIndex)` in
`O(s log s)`, marks materially overlapping ranges ambiguous, and converts a
shared boundary timestamp into an exclusive upper bound on the earlier range so
the record goes to the later session.

`attributeOwners(timestamps:orderedRanges:)` checks chronological monotonicity
in one pass. When the source order is chronological it walks timestamps and
ordered ranges with two advancing cursors in `O(n + s)`. Otherwise it sorts an
index permutation once (`O(n log n)`) and then walks. Either way, owners are
written into one `[Int32]` array and buckets are filled in a single source-order
pass, so no `records × sessions` scan exists anywhere. Events and laps use the
same walk.

Lap association runs index-first: every session's `first_lap_index` /
`number_of_laps` claim is computed against a one-pass ordinal map, conflicting
claims are dropped for all claimants, and only unclaimed sessions fall back to
timestamp ranges. A lap array index is claimed at most once globally.

## Identity

```
providerActivityID = "fit-session-v1:" + sha256Hex(
    containerSHA256 + "\u{1F}" + sourceIndex + "\u{1F}" + rawStart + …)
```

Fields are joined with an ASCII unit separator and rendered with `String(value)`
on integers only — no locale formatting, no paths, no account data. Session
`message_index` is not part of the tuple until the decoder parses it. Two
sessions in one file differ by ordinal; the same session in two containers
differs by container hash.

## Transaction

`beginBatchImport` → per-candidate parse → `stageWorkout` → release the full
`RunWorkout`, retaining only `(id, startDate, displayName)` → `commitBatchImport`
with the newest staged workout as the selection → `rollbackBatchImport` on
cancellation, zero staged workouts, or commit failure. This is the existing
`WorkoutLibraryStoreActor` sequence; no second staging format is introduced.

## Studio

`FITSessionImportSession` is a main-actor `ObservableObject` holding the
security-scoped URL, filename, scan result, selected IDs, phase, progress,
report, and non-fatal error. It mirrors `ArchiveImportSession` so the sheet,
the modal command-blocking preference, and the cancel/dismiss lifecycle behave
identically. `LibraryOperationState` gains `.scanningFITFile(filename:)` and
`.importingFITSessions`; the latter keeps the main window usable because the
sheet owns its own progress.

## Testing

`FITMultiSessionFixtureBuilder` (Core tests) emits synthetic multi-session FIT
binaries. Attribution, boundary, sport, and identity logic is additionally
tested against directly constructed `FITDecodedFile` values, which keeps the
edge-case matrix readable and Linux-clean. No real workout data is committed.
