import Foundation
@testable import RunPlayCore

/// Builds synthetic multi-session FIT binaries for tests.
///
/// Entirely synthetic: no real workout data, coordinates, or device identifiers
/// are committed to the repository.
enum FITMultiSessionFixtureBuilder {

    static let baseTimestamp: UInt32 = 1_000_000_000

    struct RecordSpec {
        var offsetSeconds: UInt32
        var hasValidTimestamp: Bool = true
        var hasValidCoordinates: Bool = true
        /// Semicircle offset applied to the fixture's base coordinate.
        var coordinateStep: Int32 = 0
        var distanceMeters: Double = 0
    }

    struct EventSpec {
        var offsetSeconds: UInt32
        var timerEventType: UInt8
        var hasValidTimestamp: Bool = true
    }

    struct LapSpec {
        var messageIndex: UInt16?
        var startOffsetSeconds: UInt32?
        var endOffsetSeconds: UInt32?
        var elapsedSeconds: UInt32 = 60
        var distanceMeters: UInt32 = 1_000
        var trigger: UInt8 = 0
    }

    struct SessionSpec {
        var startOffsetSeconds: UInt32?
        var endOffsetSeconds: UInt32?
        var sport: FITSport? = .running
        var subSport: UInt8 = 0
        var elapsedSeconds: UInt32 = 100
        /// Raw `total_elapsed_time` in milliseconds, bypassing `elapsedSeconds`.
        /// Use `0xFFFF_FFFF` to encode the FIT invalid-value sentinel.
        var elapsedMillisecondsOverride: UInt32?
        var timerSeconds: UInt32 = 100
        var distanceMeters: UInt32 = 1_000
        var firstLapIndex: UInt16 = 0xFFFF
        var numberOfLaps: UInt16 = 0xFFFF
    }

    /// Assemble a FIT container from explicit message specifications.
    ///
    /// Messages are written records → events → laps → sessions, which is the
    /// usual device layout (summary messages trail their samples).
    static func build(
        records: [RecordSpec],
        events: [EventSpec] = [],
        laps: [LapSpec] = [],
        sessions: [SessionSpec]
    ) -> Data {
        var content = Data()

        if !records.isEmpty {
            writeRecordDefinition(to: &content)
            for record in records {
                writeRecord(record, to: &content)
            }
        }
        if !events.isEmpty {
            writeEventDefinition(to: &content)
            for event in events {
                writeEvent(event, to: &content)
            }
        }
        if !laps.isEmpty {
            writeLapDefinition(to: &content)
            for lap in laps {
                writeLap(lap, to: &content)
            }
        }
        if !sessions.isEmpty {
            writeSessionDefinition(to: &content)
            for session in sessions {
                writeSession(session, to: &content)
            }
        }

        return wrap(content: content)
    }

    // MARK: - Convenience fixtures

    /// Two sequential, non-overlapping running sessions with distinct routes.
    static func twoSequentialRuns(
        firstRecordCount: Int = 10,
        secondRecordCount: Int = 10,
        gapSeconds: UInt32 = 600
    ) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<firstRecordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        let secondStart = UInt32(max(0, firstRecordCount - 1) * 10) + gapSeconds
        for index in 0..<secondRecordCount {
            records.append(RecordSpec(
                offsetSeconds: secondStart + UInt32(index * 10),
                coordinateStep: 500_000 + Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }

        let firstEnd = UInt32(max(0, firstRecordCount - 1) * 10)
        let secondEnd = secondStart + UInt32(max(0, secondRecordCount - 1) * 10)
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: firstEnd,
                    elapsedSeconds: firstEnd,
                    timerSeconds: firstEnd
                ),
                SessionSpec(
                    startOffsetSeconds: secondStart,
                    endOffsetSeconds: secondEnd,
                    elapsedSeconds: secondEnd - secondStart,
                    timerSeconds: secondEnd - secondStart
                )
            ]
        )
    }

    /// One running session followed by a session of another sport.
    static func runningPlus(sport: FITSport) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<10 {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        for index in 0..<10 {
            records.append(RecordSpec(
                offsetSeconds: 1_000 + UInt32(index * 10),
                coordinateStep: 500_000 + Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: 90,
                    elapsedSeconds: 90,
                    timerSeconds: 90
                ),
                SessionSpec(
                    startOffsetSeconds: 1_000,
                    endOffsetSeconds: 1_090,
                    sport: sport,
                    elapsedSeconds: 90,
                    timerSeconds: 90
                )
            ]
        )
    }

    /// One ordinary single-session running file.
    static func singleRunningSession(recordCount: Int = 12) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<recordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        let end = UInt32(max(0, recordCount - 1) * 10)
        return build(
            records: records,
            sessions: [
                SessionSpec(
                    startOffsetSeconds: 0,
                    endOffsetSeconds: end,
                    elapsedSeconds: end,
                    timerSeconds: end
                )
            ]
        )
    }

    /// A legacy container: GPS records but no session message at all.
    static func legacyNoSessions(recordCount: Int = 12) -> Data {
        var records: [RecordSpec] = []
        for index in 0..<recordCount {
            records.append(RecordSpec(
                offsetSeconds: UInt32(index * 10),
                coordinateStep: Int32(index) * 2_000,
                distanceMeters: Double(index) * 100
            ))
        }
        return build(records: records, sessions: [])
    }

    // MARK: - Message writers

    private static func wrap(content: Data) -> Data {
        var data = Data()
        data.append(14)                                  // header length
        data.append(16)                                  // protocol version
        data.append(contentsOf: [0x40, 0x01])            // profile version
        data.append(contentsOf: withUnsafeBytes(of: UInt32(content.count).littleEndian) { Array($0) })
        data.append(contentsOf: [0x46, 0x49, 0x54, 0x20]) // "FIT "
        data.append(contentsOf: [0x00, 0x00])            // header CRC placeholder

        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)

        data.append(content)
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))
        return data
    }

    private static func field(_ number: UInt8, _ size: UInt8, _ type: UInt8, to data: inout Data) {
        data.append(number)
        data.append(size)
        data.append(type)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    // Records — local type 0
    private static func writeRecordDefinition(to data: inout Data) {
        data.append(0x40)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x14, 0x00]) // global 20
        data.append(6)
        field(253, 4, 134, to: &data) // timestamp uint32
        field(0, 4, 133, to: &data)   // position_lat int32
        field(1, 4, 133, to: &data)   // position_long int32
        field(2, 2, 132, to: &data)   // altitude uint16
        field(5, 4, 134, to: &data)   // distance uint32
        field(6, 2, 132, to: &data)   // speed uint16
    }

    private static let baseLatitude: Int32 = 12_780_237
    private static let baseLongitude: Int32 = 1_241_516_163

    private static func writeRecord(_ spec: RecordSpec, to data: inout Data) {
        data.append(0x00)
        appendUInt32(
            spec.hasValidTimestamp ? baseTimestamp + spec.offsetSeconds : UInt32.max,
            to: &data
        )
        if spec.hasValidCoordinates {
            appendInt32(baseLatitude + spec.coordinateStep, to: &data)
            appendInt32(baseLongitude + spec.coordinateStep, to: &data)
        } else {
            appendInt32(FITParser.invalidCoordinate, to: &data)
            appendInt32(FITParser.invalidCoordinate, to: &data)
        }
        appendUInt16(UInt16((20.0 + 500) * 5), to: &data)
        appendUInt32(UInt32(spec.distanceMeters * 100), to: &data)
        appendUInt16(3_000, to: &data)
    }

    // Events — local type 3
    private static func writeEventDefinition(to data: inout Data) {
        data.append(0x43)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x15, 0x00]) // global 21
        data.append(3)
        field(253, 4, 134, to: &data) // timestamp
        field(0, 1, 0, to: &data)     // event enum
        field(1, 1, 0, to: &data)     // event_type enum
    }

    private static func writeEvent(_ spec: EventSpec, to data: inout Data) {
        data.append(0x03)
        appendUInt32(
            spec.hasValidTimestamp ? baseTimestamp + spec.offsetSeconds : UInt32.max,
            to: &data
        )
        data.append(0) // event = timer
        data.append(spec.timerEventType)
    }

    // Laps — local type 2
    private static func writeLapDefinition(to data: inout Data) {
        data.append(0x42)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x13, 0x00]) // global 19
        data.append(7)
        field(254, 2, 132, to: &data) // message_index
        field(253, 4, 134, to: &data) // timestamp
        field(2, 4, 134, to: &data)   // start_time
        field(7, 4, 134, to: &data)   // total_elapsed_time
        field(8, 4, 134, to: &data)   // total_timer_time
        field(9, 4, 134, to: &data)   // total_distance
        field(24, 1, 0, to: &data)    // lap_trigger
    }

    private static func writeLap(_ spec: LapSpec, to data: inout Data) {
        data.append(0x02)
        appendUInt16(spec.messageIndex ?? UInt16.max, to: &data)
        appendUInt32(spec.endOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        appendUInt32(spec.startOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        appendUInt32(spec.elapsedSeconds * 1_000, to: &data)
        appendUInt32(spec.elapsedSeconds * 1_000, to: &data)
        appendUInt32(spec.distanceMeters * 100, to: &data)
        data.append(spec.trigger)
    }

    // Sessions — local type 1
    private static func writeSessionDefinition(to data: inout Data) {
        data.append(0x41)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x12, 0x00]) // global 18
        data.append(9)
        field(253, 4, 134, to: &data) // timestamp
        field(2, 4, 134, to: &data)   // start_time
        field(5, 1, 0, to: &data)     // sport
        field(6, 1, 0, to: &data)     // sub_sport
        field(7, 4, 134, to: &data)   // total_elapsed_time
        field(8, 4, 134, to: &data)   // total_timer_time
        field(9, 4, 134, to: &data)   // total_distance
        field(25, 2, 132, to: &data)  // first_lap_index
        field(26, 2, 132, to: &data)  // num_laps
    }

    private static func writeSession(_ spec: SessionSpec, to data: inout Data) {
        data.append(0x01)
        appendUInt32(spec.endOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        appendUInt32(spec.startOffsetSeconds.map { baseTimestamp + $0 } ?? UInt32.max, to: &data)
        data.append(spec.sport?.rawValue ?? UInt8.max)
        data.append(spec.subSport)
        appendUInt32(spec.elapsedMillisecondsOverride ?? spec.elapsedSeconds * 1_000, to: &data)
        appendUInt32(spec.timerSeconds * 1_000, to: &data)
        appendUInt32(spec.distanceMeters * 100, to: &data)
        appendUInt16(spec.firstLapIndex, to: &data)
        appendUInt16(spec.numberOfLaps, to: &data)
    }
}

/// Deterministic non-cryptographic digest for core tests.
///
/// Identity tests assert stability and distinctness, which this satisfies
/// without pulling CryptoKit into the Linux-clean core test target. The real
/// SHA-256 path is exercised by `CryptoKitContentDigest` in platform tests.
struct TestContentDigest: ContentDigesting {
    func sha256Hex(of data: Data) -> String {
        // Two independent FNV-1a lanes widened to a 64-hex-character string, so
        // the shape matches a real digest and short tuples stay distinct.
        var low: UInt64 = 0xcbf2_9ce4_8422_2325
        var high: UInt64 = 0x9e37_79b9_7f4a_7c15
        for byte in data {
            low = (low ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            high = (high &+ UInt64(byte) &+ 1) &* 0x0000_0100_0000_01B3
            high ^= high >> 29
        }
        let block = String(format: "%016lx%016lx", low, high)
        return block + block
    }
}
