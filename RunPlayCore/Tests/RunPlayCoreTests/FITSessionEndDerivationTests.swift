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
}
