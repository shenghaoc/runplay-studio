import Foundation
@testable import RunPlayCore

/// Test-only FIT fixture generation for hotspot profiling.
///
/// Reuses `FITMultiSessionFixtureBuilder` so profiling does not invent a second
/// incompatible encoder.
enum FITProfilingFixtureBuilder {
    /// Single-session FIT with `pointCount` records, optional timer pause, and laps.
    static func singleSession(
        pointCount: Int,
        lapCount: Int = 3,
        includeTimerPause: Bool = true,
        seed: UInt64 = 4_001
    ) -> Data {
        var records: [FITMultiSessionFixtureBuilder.RecordSpec] = []
        records.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            records.append(.init(
                offsetSeconds: UInt32(index),
                coordinateStep: Int32(index) * 500,
                distanceMeters: Double(index) * 3.0
            ))
        }

        var events: [FITMultiSessionFixtureBuilder.EventSpec] = []
        if includeTimerPause, pointCount > 20 {
            let pauseAt = UInt32(pointCount / 3)
            let resumeAt = pauseAt + 30
            // FIT timer event types: 0 start, 1 stop, 2 consecutive_depreciated, 3 marker, ...
            events.append(.init(offsetSeconds: pauseAt, timerEventType: 1))
            events.append(.init(offsetSeconds: resumeAt, timerEventType: 0))
        }

        var laps: [FITMultiSessionFixtureBuilder.LapSpec] = []
        let perLap = max(1, pointCount / max(1, lapCount))
        for i in 0..<lapCount {
            let start = UInt32(i * perLap)
            let end = UInt32(min(pointCount - 1, (i + 1) * perLap))
            laps.append(.init(
                messageIndex: UInt16(i),
                startOffsetSeconds: start,
                endOffsetSeconds: end,
                elapsedSeconds: end - start,
                distanceMeters: UInt32((end - start) * 3)
            ))
        }

        let endOffset = UInt32(max(0, pointCount - 1))
        return FITMultiSessionFixtureBuilder.build(
            records: records,
            events: events,
            laps: laps,
            sessions: [
                .init(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: endOffset,
                    elapsedSeconds: endOffset,
                    timerSeconds: endOffset,
                    distanceMeters: UInt32(pointCount * 3),
                    firstLapIndex: 0,
                    numberOfLaps: UInt16(lapCount)
                )
            ]
        )
    }

    static func multiSession(
        firstCount: Int = 500,
        secondCount: Int = 500
    ) -> Data {
        FITMultiSessionFixtureBuilder.twoSequentialRuns(
            firstRecordCount: firstCount,
            secondRecordCount: secondCount,
            gapSeconds: 600
        )
    }

    static func malformedCRC() -> Data {
        var data = singleSession(pointCount: 20, lapCount: 1, includeTimerPause: false)
        // Corrupt the last two bytes (file CRC region for typical FIT wrap).
        if data.count >= 2 {
            data[data.count - 1] ^= 0xFF
            data[data.count - 2] ^= 0xAA
        }
        return data
    }

    static func emptyRecords() -> Data {
        FITMultiSessionFixtureBuilder.build(
            records: [],
            sessions: [
                .init(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 10,
                    elapsedSeconds: 10,
                    timerSeconds: 10
                )
            ]
        )
    }
}
