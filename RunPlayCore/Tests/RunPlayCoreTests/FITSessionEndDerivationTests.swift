import Foundation
import XCTest
@testable import RunPlayCore

/// Session end-boundary resolution when a device does not follow the profile's
/// convention for `session.timestamp`.
///
/// Why this suite exists: a real Garmin activity file (4,115 GPS records over
/// 68 minutes) imported as a **single route point**. The file writes
/// `session.timestamp == session.start_time` and carries the true duration
/// only in `total_elapsed_time`. The official Garmin Python SDK decodes the
/// same values, so this is the file's own shape, not a decode error — the
/// importer simply took `timestamp` literally, produced a zero-length session
/// window, and attributed exactly one record to it.
///
/// `resolveStart` already derived a missing start from the end and the elapsed
/// time; this is the mirror of that, and these tests pin both directions.
final class FITSessionEndDerivationTests: XCTestCase {

    /// `total_elapsed_time` is profile-scaled by 1000 (milliseconds).
    private func session(
        start: UInt32?,
        timestamp: UInt32?,
        elapsedMilliseconds: UInt32? = nil
    ) -> FITSessionMessage {
        var s = FITSessionMessage()
        s.startTime = start
        s.timestamp = timestamp
        s.totalElapsedTime = elapsedMilliseconds
        return s
    }

    /// The exact shape of the real file: end == start, duration only in
    /// `total_elapsed_time` (4,113.943 s).
    func testDegenerateEndIsDerivedFromElapsedTime() {
        let start: UInt32 = 1_124_014_451
        let s = session(start: start, timestamp: start, elapsedMilliseconds: 4_113_943)

        XCTAssertEqual(
            FITSessionAttribution.resolveDeclaredEnd(of: s),
            start + 4_113,
            "end == start must fall back to start + total_elapsed_time"
        )
    }

    /// The regression in product terms: the window must span the run, not one
    /// instant. A one-second window is what produced the single route point.
    func testDerivedWindowSpansTheWholeSession() {
        let start: UInt32 = 1_124_014_451
        let s = session(start: start, timestamp: start, elapsedMilliseconds: 4_113_943)
        let prepared = FITSessionAttribution.prepare(sessions: [s])

        guard case .resolved(let range) = prepared.resolutions[0] else {
            return XCTFail("expected a resolved range, got \(prepared.resolutions[0])")
        }
        XCTAssertEqual(range.start, start)
        XCTAssertEqual(range.end, start + 4_113)
        XCTAssertGreaterThan(
            range.end - range.start,
            4_000,
            "a 68-minute session must not resolve to a near-zero window"
        )
    }

    /// A well-formed file must be untouched: a genuine end later than the
    /// start always wins over the derivation.
    func testDeclaredEndIsPreferredWhenItIsAfterTheStart() {
        let start: UInt32 = 1_000_000
        let s = session(start: start, timestamp: start + 600, elapsedMilliseconds: 60_000)

        XCTAssertEqual(
            FITSessionAttribution.resolveDeclaredEnd(of: s),
            start + 600,
            "a valid declared end must not be overridden by elapsed time"
        )
    }

    /// An end *before* the start is also degenerate and must be derived.
    func testEndBeforeStartIsDerived() {
        let start: UInt32 = 1_000_000
        let s = session(start: start, timestamp: start - 50, elapsedMilliseconds: 120_000)

        XCTAssertEqual(FITSessionAttribution.resolveDeclaredEnd(of: s), start + 120)
    }

    /// With nothing to derive from, behaviour is unchanged — the importer
    /// stays fail-safe rather than inventing a window.
    func testNoElapsedTimeLeavesDeclaredEndAlone() {
        let start: UInt32 = 1_000_000
        XCTAssertEqual(
            FITSessionAttribution.resolveDeclaredEnd(of: session(start: start, timestamp: start)),
            start
        )
        XCTAssertNil(
            FITSessionAttribution.resolveDeclaredEnd(
                of: session(start: start, timestamp: nil)
            )
        )
    }

    /// The pre-existing opposite derivation must keep working.
    func testMissingStartIsStillDerivedFromEnd() {
        let end: UInt32 = 1_000_000
        let s = session(start: nil, timestamp: end, elapsedMilliseconds: 300_000)

        XCTAssertEqual(FITSessionAttribution.resolveStart(of: s), end - 300)
    }

    /// Overflow must not wrap into a bogus early end.
    func testElapsedOverflowFallsBackToDeclaredEnd() {
        let start = UInt32.max - 5
        let s = session(start: start, timestamp: start, elapsedMilliseconds: 4_000_000)

        XCTAssertEqual(FITSessionAttribution.resolveDeclaredEnd(of: s), start)
    }

    // MARK: - Multi-session containers

    /// Each session of a multi-session container derives its own end; the
    /// windows must not collapse into each other or into overlap.
    func testMultiSessionDegenerateEndsDerivePerSession() {
        let first = session(start: 100, timestamp: 100, elapsedMilliseconds: 200_000) // == start
        let second = session(start: 400, timestamp: 350, elapsedMilliseconds: 100_000) // < start
        let prepared = FITSessionAttribution.prepare(sessions: [first, second])

        XCTAssertEqual(prepared.range(at: 0)?.start, 100)
        XCTAssertEqual(prepared.range(at: 0)?.end, 300)
        XCTAssertEqual(prepared.range(at: 1)?.start, 400)
        XCTAssertEqual(prepared.range(at: 1)?.end, 500)
        XCTAssertFalse(prepared.ambiguousIndexes.contains(0))
        XCTAssertFalse(prepared.ambiguousIndexes.contains(1))

        let timestamps: [UInt32?] = [150, 320, 450]
        let owners = FITSessionAttribution.attributeOwners(
            timestamps: timestamps,
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners[0], 0)
        XCTAssertEqual(owners[1], FITSessionAttribution.unattributed, "the gap between windows owns nothing")
        XCTAssertEqual(owners[2], 1)
    }

    /// GPS-bearing-session detection must use the derived end: a session
    /// whose first GPS fix arrives strictly after a degenerate
    /// `timestamp == start_time` is still a GPS session, not a legacy
    /// whole-file fallback.
    func testDegenerateEndDoesNotHideSessionGPSRecords() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<10).map {
                FITMultiSessionFixtureBuilder.RecordSpec(
                    offsetSeconds: 10 + UInt32($0 * 10),
                    coordinateStep: Int32($0) * 2_000,
                    distanceMeters: Double($0) * 100
                )
            },
            sessions: [
                FITMultiSessionFixtureBuilder.SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 0,
                    elapsedSeconds: 200,
                    timerSeconds: 200
                )
            ]
        )
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(try FITDecoder.selectedSessionIndex(from: decoded), 0)
    }

    /// Laps of such a file anchor at their `start_time`, which lands inside
    /// the derived session windows even though every lap `timestamp` is
    /// degenerate.
    func testLapsAnchorAtStartTimeInsideDerivedMultiSessionRanges() {
        let sessions = [
            session(start: 100, timestamp: 100, elapsedMilliseconds: 200_000),
            session(start: 400, timestamp: 400, elapsedMilliseconds: 100_000)
        ]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)

        var lapZero = FITLapMessage()
        lapZero.startTime = 150
        lapZero.timestamp = 100 // degenerate: precedes its own start
        var lapOne = FITLapMessage()
        lapOne.startTime = 450
        lapOne.timestamp = 100

        let attributed = FITSessionAttribution.attributeLaps(
            laps: [lapZero, lapOne],
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertEqual(attributed[0], [0])
        XCTAssertEqual(attributed[1], [1])
    }

    // MARK: - End to end

    /// A synthetic container with the real file's exact message shape —
    /// session `timestamp == start_time` with the duration only in
    /// `total_elapsed_time`, lap end timestamps at or before their own
    /// `start_time` — must import with every record and every lap retained.
    /// Values are synthetic; only the shape mirrors the device file.
    func testRealFileShapeContainerImportsEveryRecordAndLap() throws {
        let data = FITMultiSessionFixtureBuilder.build(
            records: (0..<30).map {
                FITMultiSessionFixtureBuilder.RecordSpec(
                    offsetSeconds: UInt32($0 * 10),
                    coordinateStep: Int32($0) * 2_000,
                    distanceMeters: Double($0) * 100
                )
            },
            laps: [
                FITMultiSessionFixtureBuilder.LapSpec(
                    messageIndex: 0,
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 0,
                    elapsedSeconds: 140
                ),
                FITMultiSessionFixtureBuilder.LapSpec(
                    messageIndex: 1,
                    startOffsetSeconds: 140,
                    endOffsetSeconds: 0,
                    elapsedSeconds: 150
                )
            ],
            sessions: [
                FITMultiSessionFixtureBuilder.SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 0,
                    elapsedSeconds: 290,
                    timerSeconds: 290
                )
            ]
        )

        let workout = try FITImporter().importWorkout(data: data, suggestedName: "degenerate.fit")

        XCTAssertEqual(workout.routePoints.count, 30, "the whole run, not a single point")
        XCTAssertEqual(workout.recordedLaps.count, 2, "no lap may be lost to the degenerate window")
        XCTAssertEqual(workout.recordedLapDiagnostics.sourceLapCount, 2)
        XCTAssertEqual(workout.recordedLapDiagnostics.malformedLapCount, 0)
        XCTAssertEqual(workout.recordedLaps[0].elapsedSeconds, 140, accuracy: 0.001)
        XCTAssertEqual(workout.recordedLaps[1].elapsedSeconds, 150, accuracy: 0.001)
    }
}
