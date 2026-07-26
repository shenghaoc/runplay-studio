import XCTest
@testable import RunPlayCore

/// Boundary resolution, record/event/lap attribution, and complexity behaviour.
final class FITSessionAttributionTests: XCTestCase {

    // MARK: - Helpers

    private func session(
        start: UInt32?,
        end: UInt32?,
        elapsedSeconds: UInt32? = nil,
        sport: FITSport? = .running,
        firstLapIndex: UInt16? = nil,
        numberOfLaps: UInt16? = nil
    ) -> FITSessionMessage {
        var message = FITSessionMessage()
        message.startTime = start ?? UInt32.max
        message.timestamp = end ?? UInt32.max
        message.totalElapsedTime = elapsedSeconds.map { $0 * 1_000 } ?? UInt32.max
        message.sport = sport?.rawValue
        message.firstLapIndex = firstLapIndex ?? UInt16.max
        message.numberOfLaps = numberOfLaps ?? UInt16.max
        return message
    }

    private func record(_ timestamp: UInt32?) -> FITRecordMessage {
        var message = FITRecordMessage()
        message.timestamp = timestamp ?? UInt32.max
        return message
    }

    private func lap(
        messageIndex: UInt16?,
        start: UInt32?,
        end: UInt32?
    ) -> FITLapMessage {
        var message = FITLapMessage()
        message.messageIndex = messageIndex ?? UInt16.max
        message.startTime = start ?? UInt32.max
        message.timestamp = end ?? UInt32.max
        return message
    }

    // MARK: - Boundary resolution

    func testStartPrefersStartTime() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 200)
        ])
        XCTAssertEqual(prepared.range(at: 0)?.start, 100)
        XCTAssertEqual(prepared.range(at: 0)?.end, 200)
        XCTAssertNil(prepared.problem(at: 0))
    }

    func testStartDerivedFromEndMinusElapsedWhenStartTimeInvalid() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: nil, end: 500, elapsedSeconds: 120)
        ])
        XCTAssertEqual(prepared.range(at: 0)?.start, 380)
        XCTAssertEqual(prepared.range(at: 0)?.end, 500)
    }

    func testMissingStartIsNotImportable() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: nil, end: 500, elapsedSeconds: nil)
        ])
        XCTAssertNil(prepared.range(at: 0))
        XCTAssertEqual(prepared.problem(at: 0), .missingStart)
    }

    func testMissingEndFallsBackToNextOrderedSessionStart() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: nil),
            session(start: 400, end: 500)
        ])
        let first = prepared.range(at: 0)
        XCTAssertEqual(first?.end, 400)
        XCTAssertEqual(first?.upperExclusive, 400, "Derived end must be exclusive")
        XCTAssertTrue(first?.endWasDerived == true)
    }

    func testMissingEndWithNoNextSessionIsNotImportable() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 400, end: 500),
            session(start: 600, end: nil)
        ])
        XCTAssertNil(prepared.range(at: 1))
        XCTAssertEqual(prepared.problem(at: 1), .missingEnd)
    }

    func testMissingEndWithUnorderedNextSessionIsNotImportable() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 600, end: nil),
            session(start: 100, end: 200)
        ])
        XCTAssertNil(prepared.range(at: 0))
        XCTAssertEqual(prepared.problem(at: 0), .missingEnd)
    }

    func testEndBeforeStartIsInvalidOrder() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 900, end: 100)
        ])
        XCTAssertEqual(prepared.problem(at: 0), .invalidOrder)
    }

    // MARK: - Shared boundary

    func testSharedBoundaryRecordBelongsToLaterSession() {
        let sessions = [
            session(start: 100, end: 200),
            session(start: 200, end: 300)
        ]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        XCTAssertTrue(prepared.ambiguousIndexes.isEmpty, "Touching ranges are not overlapping")

        let owners = FITSessionAttribution.attributeOwners(
            timestamps: [150, 200, 250],
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [0, 1, 1])
    }

    func testNonSharedInclusiveEndKeepsItsBoundaryRecord() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ])
        let owners = FITSessionAttribution.attributeOwners(
            timestamps: [200, 300],
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [0, 1])
    }

    func testZeroLengthSessionDoesNotDemoteItself() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 100)
        ])
        let owners = FITSessionAttribution.attributeOwners(
            timestamps: [100],
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [0])
    }

    // MARK: - Overlap

    func testMaterialOverlapMarksBothSessionsAmbiguous() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 300),
            session(start: 200, end: 400)
        ])
        XCTAssertEqual(prepared.ambiguousIndexes, [0, 1])
        XCTAssertTrue(prepared.orderedRanges.isEmpty)

        let owners = FITSessionAttribution.attributeOwners(
            timestamps: [250],
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [FITSessionAttribution.unattributed],
                       "Overlapping records must not be guessed into a session")
    }

    func testFullyContainedSessionIsAmbiguous() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 900),
            session(start: 200, end: 300)
        ])
        XCTAssertEqual(prepared.ambiguousIndexes, [0, 1])
    }

    func testNonOverlappingThirdSessionStaysImportable() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 300),
            session(start: 200, end: 400),
            session(start: 500, end: 600)
        ])
        XCTAssertEqual(prepared.ambiguousIndexes, [0, 1])
        XCTAssertEqual(prepared.orderedRanges.map(\.sourceIndex), [2])
    }

    // MARK: - Record attribution

    func testRecordsSplitBetweenSequentialSessions() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ])
        let records = [100, 150, 200, 250, 300, 400].map { record(UInt32($0)) }
        let owners = FITSessionAttribution.attributeOwners(
            timestamps: FITSessionAttribution.recordTimestamps(records),
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [0, 0, 0, -1, 1, 1])

        let buckets = FITSessionAttribution.buckets(owners: owners, sessionCount: 2)
        XCTAssertEqual(buckets[0], [0, 1, 2])
        XCTAssertEqual(buckets[1], [4, 5])
    }

    func testUntimestampedRecordsAreExcluded() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ])
        let records = [record(120), record(nil), record(320)]
        let owners = FITSessionAttribution.attributeOwners(
            timestamps: FITSessionAttribution.recordTimestamps(records),
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [0, FITSessionAttribution.unattributed, 1])
    }

    func testNonChronologicalSourceOrderStillAttributesCorrectlyAndPreservesOrder() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ])
        // Deliberately out of order in the container.
        let timestamps: [UInt32?] = [350, 100, 400, 150, 300]
        let owners = FITSessionAttribution.attributeOwners(
            timestamps: timestamps,
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [1, 0, 1, 0, 1])

        let buckets = FITSessionAttribution.buckets(owners: owners, sessionCount: 2)
        XCTAssertEqual(buckets[0], [1, 3], "Buckets must stay in source order")
        XCTAssertEqual(buckets[1], [0, 2, 4])
    }

    // MARK: - Event attribution

    func testEventsScopedToOwningSession() {
        let prepared = FITSessionAttribution.prepare(sessions: [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ])
        var pauseInFirst = FITEventMessage()
        pauseInFirst.timestamp = 150
        pauseInFirst.event = 0
        pauseInFirst.eventType = 1

        var untimestamped = FITEventMessage()
        untimestamped.timestamp = UInt32.max
        untimestamped.event = 0
        untimestamped.eventType = 0

        var startInSecond = FITEventMessage()
        startInSecond.timestamp = 300
        startInSecond.event = 0
        startInSecond.eventType = 0

        let owners = FITSessionAttribution.attributeOwners(
            timestamps: FITSessionAttribution.eventTimestamps(
                [pauseInFirst, untimestamped, startInSecond]
            ),
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, [0, FITSessionAttribution.unattributed, 1])
    }

    // MARK: - Lap attribution

    func testLapsAssociatedByFirstLapIndexAndCount() {
        let sessions = [
            session(start: 100, end: 200, firstLapIndex: 0, numberOfLaps: 2),
            session(start: 300, end: 400, firstLapIndex: 2, numberOfLaps: 1)
        ]
        let laps = [
            lap(messageIndex: 0, start: 100, end: 150),
            lap(messageIndex: 1, start: 150, end: 200),
            lap(messageIndex: 2, start: 300, end: 400)
        ]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertEqual(result[0], [0, 1])
        XCTAssertEqual(result[1], [2])
    }

    func testLapMessageIndexUsesLowerTwelveBits() {
        // Bit 15 is the FIT `selected` flag; it must not shift the ordinal.
        let sessions = [session(start: 100, end: 200, firstLapIndex: 0, numberOfLaps: 1)]
        let laps = [lap(messageIndex: 0x8000, start: 100, end: 200)]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertEqual(result[0], [0])
    }

    func testLapTimestampFallbackWhenIndexMetadataAbsent() {
        let sessions = [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ]
        let laps = [
            lap(messageIndex: nil, start: 120, end: 180),
            lap(messageIndex: nil, start: 320, end: 380)
        ]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertEqual(result[0], [0])
        XCTAssertEqual(result[1], [1])
    }

    func testUnattributableLapIsExcluded() {
        let sessions = [
            session(start: 100, end: 200),
            session(start: 300, end: 400)
        ]
        let laps = [lap(messageIndex: nil, start: nil, end: nil)]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertTrue(result.allSatisfy(\.isEmpty))
    }

    func testConflictingIndexClaimsFallBackToTimestamps() {
        // Both sessions claim lap ordinal 0. Neither may own it by index.
        let sessions = [
            session(start: 100, end: 200, firstLapIndex: 0, numberOfLaps: 1),
            session(start: 300, end: 400, firstLapIndex: 0, numberOfLaps: 1)
        ]
        let laps = [lap(messageIndex: 0, start: 320, end: 380)]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertTrue(result[0].isEmpty)
        XCTAssertEqual(result[1], [0], "Timestamp fallback resolves the conflicted lap")
    }

    func testNoLapAppearsInTwoSessions() {
        let sessions = [
            session(start: 100, end: 200, firstLapIndex: 0, numberOfLaps: 1),
            session(start: 300, end: 400)
        ]
        // The indexed lap also falls inside session 1's timestamp range.
        let laps = [lap(messageIndex: 0, start: 350, end: 380)]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        let owners = result.enumerated().flatMap { index, laps in laps.map { _ in index } }
        XCTAssertEqual(owners.count, 1, "A lap may belong to at most one session")
        XCTAssertEqual(result[0], [0], "Index metadata wins over timestamp range")
    }

    func testSessionDeclaringZeroLapsAbsorbsNoStrayLaps() {
        let sessions = [
            session(start: 100, end: 200, firstLapIndex: 0, numberOfLaps: 0),
            session(start: 300, end: 400)
        ]
        let laps = [lap(messageIndex: nil, start: 120, end: 180)]
        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        let result = FITSessionAttribution.attributeLaps(
            laps: laps,
            sessions: sessions,
            prepared: prepared
        )
        XCTAssertTrue(result[0].isEmpty)
        XCTAssertTrue(result[1].isEmpty)
    }

    // MARK: - Complexity

    func testAttributionIsLinearInRecordsNotRecordsTimesSessions() {
        // 100 sessions × 100,000 records. A records × sessions scan would be
        // 10,000,000 range comparisons; the walk performs O(r + s).
        let sessionCount = 100
        let recordsPerSession = 1_000
        var sessions: [FITSessionMessage] = []
        var timestamps: [UInt32?] = []
        for sessionIndex in 0..<sessionCount {
            let start = UInt32(sessionIndex) * 10_000
            sessions.append(session(start: start, end: start + 5_000))
            for offset in 0..<recordsPerSession {
                timestamps.append(start + UInt32(offset))
            }
        }

        let prepared = FITSessionAttribution.prepare(sessions: sessions)
        XCTAssertEqual(prepared.orderedRanges.count, sessionCount)
        XCTAssertTrue(prepared.ambiguousIndexes.isEmpty)

        let owners = FITSessionAttribution.attributeOwners(
            timestamps: timestamps,
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners.count, sessionCount * recordsPerSession)
        XCTAssertFalse(owners.contains(FITSessionAttribution.unattributed))

        let buckets = FITSessionAttribution.buckets(owners: owners, sessionCount: sessionCount)
        for sessionIndex in 0..<sessionCount {
            XCTAssertEqual(buckets[sessionIndex].count, recordsPerSession)
        }

        // Deterministic: repeating the walk yields identical owners.
        let repeated = FITSessionAttribution.attributeOwners(
            timestamps: timestamps,
            orderedRanges: prepared.orderedRanges
        )
        XCTAssertEqual(owners, repeated)
    }

    func testMessageIndexBuildChecksCancellationDuringAttribution() {
        let sessions = [
            session(start: 0, end: 5_000),
            session(start: 10_000, end: 15_000)
        ]
        let records = (0..<10_000).map { record(UInt32($0)) }
        let decodedFile = FITDecodedFile(sessions: sessions, records: records)
        // Entry + boundary preparation consume two probes, timestamp extraction
        // consumes ten more at a 1,000-record stride, and the owner walk checks
        // once before its first chronological-order probe. Cancel on that next
        // probe to prove the attribution walk itself remains interruptible.
        let probe = AttributionCancellationProbe(cancelOnCheck: 14)

        XCTAssertThrowsError(
            try FITSessionMessageIndex.build(
                decodedFile: decodedFile,
                cancellationCheckStride: 1_000,
                isCancelled: { probe.check() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(probe.checkCount, 14)
    }
}

private final class AttributionCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnCheck: Int
    private var checks = 0

    init(cancelOnCheck: Int) {
        self.cancelOnCheck = cancelOnCheck
    }

    var checkCount: Int {
        lock.withLock { checks }
    }

    func check() -> Bool {
        lock.withLock {
            checks += 1
            return checks >= cancelOnCheck
        }
    }
}
