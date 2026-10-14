import Foundation
import XCTest
@testable import RunPlayCore

/// Direct tests of the import-time heart-rate index.
///
/// The parser's tests exercise the ceiling and the filtered second pass through
/// `parse(openStream:)`; these exercise the index on its own, so a regression in
/// the buffer is located rather than only observed through a whole document.
/// Every fixture here is invented; nothing is copied from a real export.
final class AppleHealthHeartRateIndexTests: XCTestCase {

    private func reading(
        at start: Int64,
        duration: UInt32 = 0,
        bpm: Double = 120
    ) -> AppleHealthHeartRateReading {
        AppleHealthHeartRateReading(
            startSeconds: start,
            durationSeconds: duration,
            beatsPerMinute: bpm
        )
    }

    private func window(from start: Int64, to end: Int64) -> AppleHealthWorkoutWindow {
        AppleHealthWorkoutWindow(
            startSeconds: start,
            endSeconds: end,
            activityType: "HKWorkoutActivityTypeRunning",
            utcOffsetSeconds: 0
        )
    }

    // MARK: - Retention and the ceiling

    func testRetainsReadingsAndCountsEveryOffer() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 1))
        index.append(reading(at: 2))
        XCTAssertEqual(index.retainedCount, 2)
        XCTAssertEqual(index.offeredCount, 2)
        XCTAssertFalse(index.releasedByCeiling)
    }

    func testCeilingReleasesTheBufferAndReportsIt() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 2)
        index.append(reading(at: 1))
        index.append(reading(at: 2))
        index.append(reading(at: 3))
        XCTAssertTrue(index.releasedByCeiling)
        XCTAssertEqual(index.retainedCount, 0)
        // Every offer is still counted, including the ones not retained.
        XCTAssertEqual(index.offeredCount, 3)
    }

    func testCeilingIsNotReportedWhenItIsExactlyReached() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 2)
        index.append(reading(at: 1))
        index.append(reading(at: 2))
        XCTAssertFalse(index.releasedByCeiling)
        XCTAssertEqual(index.retainedCount, 2)
    }

    func testZeroCeilingReleasesImmediately() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 0)
        index.append(reading(at: 1))
        XCTAssertTrue(index.releasedByCeiling)
        XCTAssertEqual(index.retainedCount, 0)
    }

    func testNegativeCeilingIsClampedToZero() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: -5)
        XCTAssertEqual(index.sampleCountCeiling, 0)
        index.append(reading(at: 1))
        XCTAssertTrue(index.releasedByCeiling)
    }

    // MARK: - The filtered second pass

    func testFilteredPassRetainsOnlyInWindowReadings() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.beginFilteredPass(windows: [window(from: 100, to: 200)])
        index.append(reading(at: 50))    // before the window
        index.append(reading(at: 150))   // inside
        index.append(reading(at: 250))   // after the window
        XCTAssertEqual(index.retainedCount, 1)
        // Rejected offers are counted too: `offeredCount` is what the ceiling sees.
        XCTAssertEqual(index.offeredCount, 3)
    }

    func testFilteredPassRetainsAReadingThatSpansTheWindowStart() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.beginFilteredPass(windows: [window(from: 100, to: 200)])
        index.append(reading(at: 90, duration: 20))  // 90...110 overlaps 100
        XCTAssertEqual(index.retainedCount, 1)
    }

    func testFilteredPassTreatsTheWindowEndAsClosed() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.beginFilteredPass(windows: [window(from: 100, to: 200)])
        index.append(reading(at: 200))  // starts exactly when the window ends
        XCTAssertEqual(index.retainedCount, 1)
    }

    func testFilteredPassWithNoWindowsRetainsNothing() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.beginFilteredPass(windows: [])
        index.append(reading(at: 150))
        XCTAssertEqual(index.retainedCount, 0)
        XCTAssertEqual(index.offeredCount, 1)
    }

    func testFilteredPassClearsTheEarlierCeilingSignal() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 1)
        index.append(reading(at: 1))
        index.append(reading(at: 2))
        XCTAssertTrue(index.releasedByCeiling)
        index.beginFilteredPass(windows: [window(from: 0, to: 10)])
        XCTAssertFalse(index.releasedByCeiling)
        XCTAssertEqual(index.offeredCount, 0)
        XCTAssertEqual(index.retainedCount, 0)
    }

    // MARK: - The finalized lookup

    func testFinalizeSortsByStartThenDuration() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 30, duration: 5, bpm: 3))
        index.append(reading(at: 10, duration: 9, bpm: 1))
        index.append(reading(at: 10, duration: 2, bpm: 2))
        let lookup = index.finalize()
        XCTAssertEqual(lookup.count, 3)
        XCTAssertEqual(
            lookup.allReadings,
            [
                reading(at: 10, duration: 2, bpm: 2),
                reading(at: 10, duration: 9, bpm: 1),
                reading(at: 30, duration: 5, bpm: 3),
            ]
        )
    }

    func testRangeQueryFindsAReadingThatStartedBeforeTheWindow() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 100, duration: 60, bpm: 140))
        index.append(reading(at: 300, duration: 0, bpm: 150))
        let lookup = index.finalize()
        // The 140 reading begins at 100 and reaches 160, so it overlaps 120...130
        // even though its start is before the query window.
        XCTAssertEqual(lookup.readings(inWindowStart: 120, end: 130).map(\.beatsPerMinute), [140])
    }

    func testRangeQueryExcludesAReadingThatEndsBeforeTheWindow() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 100, duration: 10, bpm: 140))
        let lookup = index.finalize()
        XCTAssertTrue(lookup.readings(inWindowStart: 200, end: 300).isEmpty)
    }

    func testRangeQueryOverAnEmptyIndexIsEmpty() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        let lookup = index.finalize()
        XCTAssertTrue(lookup.isEmpty)
        XCTAssertEqual(lookup.count, 0)
        XCTAssertTrue(lookup.readings(in: window(from: 0, to: 10)).isEmpty)
    }

    func testRangeQueryRejectsAReversedInterval() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 100))
        let lookup = index.finalize()
        XCTAssertTrue(lookup.readings(inWindowStart: 200, end: 100).isEmpty)
    }

    func testRangeQueryIncludesBothWindowBoundaries() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 100, duration: 0, bpm: 1))
        index.append(reading(at: 200, duration: 0, bpm: 2))
        let lookup = index.finalize()
        XCTAssertEqual(lookup.readings(inWindowStart: 100, end: 200).map(\.beatsPerMinute), [1, 2])
    }

    func testMaximumDurationTracksTheLongestRetainedReading() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        index.append(reading(at: 1, duration: 5))
        index.append(reading(at: 2, duration: 90))
        index.append(reading(at: 3, duration: 12))
        XCTAssertEqual(index.maximumDurationSeconds, 90)
    }

    func testMaximumDurationResetsWhenTheCeilingReleasesTheBuffer() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 1)
        index.append(reading(at: 1, duration: 90))
        index.append(reading(at: 2, duration: 0))
        XCTAssertTrue(index.releasedByCeiling)
        XCTAssertEqual(index.maximumDurationSeconds, 0)
    }

    // MARK: - Reading arithmetic

    func testEndSecondsSaturatesInsteadOfWrapping() {
        let reading = AppleHealthHeartRateReading(
            startSeconds: Int64.max - 1,
            durationSeconds: UInt32.max,
            beatsPerMinute: 120
        )
        XCTAssertEqual(reading.endSeconds, Int64.max)
    }

    func testEndSecondsIsTheStartPlusTheDuration() {
        XCTAssertEqual(reading(at: 1_000, duration: 120).endSeconds, 1_120)
    }

    // MARK: - Review fixes: the ceiling, ordering and the window filter

    func testReadingsAfterTheCeilingTripsAreCountedButNotRetained() {
        var index = AppleHealthHeartRateIndex(sampleCountCeiling: 2)
        for second in 0..<3 { index.append(reading(at: Int64(second), duration: 1, bpm: 140)) }
        XCTAssertTrue(index.releasedByCeiling)
        XCTAssertEqual(index.retainedCount, 0)

        // Fewer than the ceiling, so a refilled buffer is not released again.
        for second in 3..<5 { index.append(reading(at: Int64(second), duration: 1, bpm: 140)) }
        XCTAssertEqual(index.retainedCount, 0, "readings after the trip must not refill the buffer")
        XCTAssertEqual(index.offeredCount, 5)
        XCTAssertEqual(index.finalize().count, 0)
    }

    func testFinalizeOrdersEqualSpansByRateWhateverTheInsertionOrder() {
        let low = reading(at: 10, duration: 5, bpm: 120)
        let high = reading(at: 10, duration: 5, bpm: 150)
        var highFirst = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        highFirst.append(high)
        highFirst.append(low)
        var lowFirst = AppleHealthHeartRateIndex(sampleCountCeiling: 10)
        lowFirst.append(low)
        lowFirst.append(high)

        XCTAssertEqual(highFirst.finalize().allReadings, [low, high])
        XCTAssertEqual(lowFirst.finalize().allReadings, [low, high])
    }

    /// The filtered pass keeps exactly the readings a scan over every window
    /// keeps: random windows (overlapping, touching, nested, and the odd
    /// reversed one) against random readings, from a fixed seed.
    func testFilteredPassKeepsWhatAScanOverEveryWindowKeeps() {
        var state: UInt64 = 0x5EED_0F_C0FFEE
        func next(_ bound: Int64) -> Int64 {
            // SplitMix64: deterministic on every platform.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int64((z ^ (z >> 31)) % UInt64(bound))
        }
        for _ in 0..<60 {
            // Deliberate edges first: a one-second gap between two windows, two
            // windows that touch, and a window nested in another, each with
            // readings on and around the boundaries.
            let base = next(9_000)
            var windows: [AppleHealthWorkoutWindow] = [
                window(from: base, to: base + 50),
                window(from: base + 52, to: base + 100),
                window(from: base + 200, to: base + 250),
                window(from: base + 250, to: base + 290),
                window(from: base + 400, to: base + 500),
                window(from: base + 420, to: base + 440),
            ]
            var readings: [AppleHealthHeartRateReading] = [50, 51, 52, 199, 250, 291, 399, 501].map {
                reading(at: base + $0, duration: 0, bpm: 120)
            }
            readings.append(reading(at: base + 45, duration: 10, bpm: 130))
            for _ in 0..<(1 + next(40)) {
                let start = next(10_000)
                windows.append(next(25) == 0
                    ? window(from: start + 300, to: start)
                    : window(from: start, to: start + next(600)))
            }
            for _ in 0..<400 {
                readings.append(reading(at: next(10_800) - 100, duration: UInt32(next(120)), bpm: Double(60 + next(140))))
            }
            let expected = readings.filter { candidate in
                windows.contains { candidate.startSeconds <= $0.endSeconds && candidate.endSeconds >= $0.startSeconds }
            }

            var index = AppleHealthHeartRateIndex(sampleCountCeiling: 1_000_000)
            index.beginFilteredPass(windows: windows)
            for candidate in readings { index.append(candidate) }
            var reference = AppleHealthHeartRateIndex(sampleCountCeiling: 1_000_000)
            for candidate in expected { reference.append(candidate) }

            XCTAssertEqual(index.finalize().allReadings, reference.finalize().allReadings)
        }
    }
}
