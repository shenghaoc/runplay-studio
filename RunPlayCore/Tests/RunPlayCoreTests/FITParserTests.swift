import XCTest
@testable import RunPlayCore

final class FITParserTests: XCTestCase {

    func testNegativeFITCoordinatesUseBitPatternSemantics() throws {
        let data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            (timestamp: 1_010, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
        ])

        let decoded = try FITParser.parse(data: data)
        let points = FITDecoder.decode(records: decoded.records)

        XCTAssertEqual(points.count, 2)
        XCTAssertGreaterThan(points[0].latitude, 0)
        XCTAssertLessThan(points[0].longitude, 0)
        XCTAssertGreaterThan(points[1].distanceFromStartMeters, points[0].distanceFromStartMeters)
    }

    func testCompressedTimestampHeaderFailsWithoutBaseline() {
        let data = Self.fitData(rawContent: Data([0x80]))

        XCTAssertThrowsError(try FITParser.parse(data: data)) { error in
            guard case FITError.compressedTimestampWithoutBaseline = error else {
                XCTFail("Expected compressedTimestampWithoutBaseline, got \(error)")
                return
            }
        }
    }

    func testValidCRCParsesSuccessfully() throws {
        let data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            (timestamp: 1_010, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
        ])

        // Should not throw — CRCs are valid
        let decoded = try FITParser.parse(data: data)
        XCTAssertEqual(decoded.records.count, 2)
    }

    func testZeroHeaderCRCSkipsValidation() throws {
        // Header CRC of 0x0000 means "not computed" — parser should skip the check
        let data = Self.fitData(
            records: [
                (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0)
            ],
            zeroHeaderCRC: true
        )

        // Should not throw — 0x0000 header CRC is treated as absent
        let decoded = try FITParser.parse(data: data)
        XCTAssertEqual(decoded.records.count, 1)
    }

    func test12ByteHeaderParsesSuccessfully() throws {
        // 12-byte headers have no CRC field at all — parser should accept them
        let data = Self.fitData(
            records: [
                (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
                (timestamp: 1_010, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
            ],
            headerLength: 12
        )

        let decoded = try FITParser.parse(data: data)
        XCTAssertEqual(decoded.records.count, 2)
    }

    func testCRC16KnownAnswer() {
        // Standard CRC-16/ARC test vector: "123456789" = 0xBB3D
        let input: [UInt8] = Array("123456789".utf8)
        let result = FITParser.crc16(over: input)
        XCTAssertEqual(result, 0xBB3D, "CRC-16/ARC of '123456789' should be 0xBB3D")
    }

    func testCorruptHeaderCRCThrows() {
        var data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0)
        ])
        // Flip a byte in the header CRC
        data[12] ^= 0xFF

        XCTAssertThrowsError(try FITParser.parse(data: data)) { error in
            guard case FITError.headerCRCMismatch = error else {
                XCTFail("Expected headerCRCMismatch, got \(error)")
                return
            }
        }
    }

    func testCorruptFileCRCThrows() {
        var data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0)
        ])
        // Flip a byte in the file CRC (last 2 bytes)
        data[data.count - 1] ^= 0xFF

        XCTAssertThrowsError(try FITParser.parse(data: data)) { error in
            guard case FITError.fileCRCMismatch = error else {
                XCTFail("Expected fileCRCMismatch, got \(error)")
                return
            }
        }
    }

    func testTrailingBytesAfterFileCRCThrows() {
        var data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0)
        ])
        data.append(0x00)

        XCTAssertThrowsError(try FITParser.parse(data: data)) { error in
            guard case FITError.corruptedData = error else {
                XCTFail("Expected corruptedData, got \(error)")
                return
            }
        }
    }

    func testTruncatedDataThrows() {
        var data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0)
        ])
        // Truncate before the file CRC
        data = data.prefix(data.count - 4)

        XCTAssertThrowsError(try FITParser.parse(data: data)) { error in
            guard case FITError.unexpectedEndOfFile = error else {
                XCTFail("Expected unexpectedEndOfFile, got \(error)")
                return
            }
        }
    }

    func testDeveloperDataFieldsAreSkippedWithoutDesyncing() throws {
        let data = Self.fitDataWithDeveloperFields(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            (timestamp: 1_010, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
        ])

        let decoded = try FITParser.parse(data: data)
        let points = FITDecoder.decode(records: decoded.records)

        XCTAssertEqual(decoded.records.count, 2)
        XCTAssertEqual(points.count, 2)
        XCTAssertGreaterThan(points[1].distanceFromStartMeters, points[0].distanceFromStartMeters)
    }

    func testParserEnforcesDecodedMessageLimit() {
        let data = Self.fitData(rawContent: Self.eventStreamContent(messageCount: 3))

        XCTAssertThrowsError(
            try FITParser.parse(
                data: data,
                isCancelled: { false },
                maximumDecodedMessageCount: 2
            )
        ) { error in
            guard case FITError.corruptedData(let message) = error else {
                XCTFail("Expected decoded-message limit error, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Decoded message count exceeds maximum"))
        }
    }

    func testParserCooperativelyCancelsAtCheckpoint() {
        let data = Self.fitData(rawContent: Self.eventStreamContent(messageCount: 1_001))
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try FITParser.parse(data: data, isCancelled: {
                cancellationChecks += 1
                return cancellationChecks == 2
            })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 2)
    }

    func testFITDecoderReturnsEmptyWhenGPSRecordsHaveNoTimestamps() {
        let records = [
            Self.record(timestamp: nil, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            Self.record(timestamp: nil, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
        ]

        let points = FITDecoder.decode(records: records)

        XCTAssertTrue(points.isEmpty)
    }

    func testFITDecoderInterpolatesPartialTimestamps() {
        let records = [
            Self.record(timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            Self.record(timestamp: nil, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20),
            Self.record(timestamp: 1_020, latDegrees: 37.7751, lonDegrees: -122.4196, distanceMeters: 40),
            Self.record(timestamp: nil, latDegrees: 37.7752, lonDegrees: -122.4197, distanceMeters: 60)
        ]

        let points = FITDecoder.decode(records: records)

        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[1].timestamp.timeIntervalSince(points[0].timestamp), 10, accuracy: 0.001)
        XCTAssertEqual(points[2].timestamp.timeIntervalSince(points[1].timestamp), 10, accuracy: 0.001)
        XCTAssertEqual(points[3].timestamp.timeIntervalSince(points[2].timestamp), 1, accuracy: 0.001)
    }

    private static func fitData(
        records: [(timestamp: UInt32, latDegrees: Double, lonDegrees: Double, distanceMeters: Double)],
        headerLength: UInt8 = 14,
        zeroHeaderCRC: Bool = false
    ) -> Data {
        var content = Data()
        writeDefinition(to: &content)
        for record in records {
            content.append(0x00)
            append(record.timestamp, to: &content)
            append(semicircles(record.latDegrees), to: &content)
            append(semicircles(record.lonDegrees), to: &content)
            append(UInt32(record.distanceMeters * 100), to: &content)
        }
        return fitData(rawContent: content, headerLength: headerLength, zeroHeaderCRC: zeroHeaderCRC)
    }

    private static func fitDataWithDeveloperFields(
        records: [(timestamp: UInt32, latDegrees: Double, lonDegrees: Double, distanceMeters: Double)]
    ) -> Data {
        var content = Data()
        writeDefinition(to: &content, includeDeveloperField: true)
        for record in records {
            content.append(0x00)
            append(record.timestamp, to: &content)
            append(semicircles(record.latDegrees), to: &content)
            append(semicircles(record.lonDegrees), to: &content)
            append(UInt32(record.distanceMeters * 100), to: &content)
            content.append(contentsOf: [0x12, 0x34])
        }
        return fitData(rawContent: content)
    }

    private static func eventStreamContent(messageCount: Int) -> Data {
        var content = Data()
        content.append(0x40) // definition, local type 0
        content.append(0x00) // reserved
        content.append(0x00) // little-endian
        content.append(contentsOf: [0x15, 0x00]) // global msg 21 (event)
        content.append(1)
        writeField(0, size: 1, type: 0, to: &content) // event enum

        for _ in 0..<messageCount {
            content.append(0x00)
            content.append(0)
        }
        return content
    }

    private static func fitData(
        rawContent content: Data,
        headerLength: UInt8 = 14,
        zeroHeaderCRC: Bool = false
    ) -> Data {
        var data = Data()
        data.append(headerLength)
        data.append(16)
        data.append(contentsOf: [0x40, 0x01])
        append(UInt32(content.count), to: &data)
        data.append(contentsOf: [0x46, 0x49, 0x54, 0x20])
        if headerLength == 14 {
            // Placeholder header CRC — will be patched below
            data.append(contentsOf: [0x00, 0x00])
            if !zeroHeaderCRC {
                // Patch header CRC (covers bytes 0..<12)
                let headerCRC = FITParser.crc16(over: data[0..<12])
                data[12] = UInt8(headerCRC & 0xFF)
                data[13] = UInt8(headerCRC >> 8)
            }
        }
        data.append(content)
        // Compute and append file CRC
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))
        return data
    }

    private static func writeDefinition(to data: inout Data, includeDeveloperField: Bool = false) {
        data.append(includeDeveloperField ? 0x60 : 0x40)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x14, 0x00])
        data.append(4)
        writeField(253, size: 4, type: 134, to: &data)
        writeField(0, size: 4, type: 133, to: &data)
        writeField(1, size: 4, type: 133, to: &data)
        writeField(5, size: 4, type: 134, to: &data)

        if includeDeveloperField {
            data.append(1)
            data.append(0)
            data.append(2)
            data.append(0)
        }
    }

    private static func writeField(_ number: UInt8, size: UInt8, type: UInt8, to data: inout Data) {
        data.append(number)
        data.append(size)
        data.append(type)
    }

    private static func record(
        timestamp: UInt32?,
        latDegrees: Double,
        lonDegrees: Double,
        distanceMeters: Double
    ) -> FITRecordMessage {
        var record = FITRecordMessage()
        record.timestamp = timestamp
        record.positionLat = semicircles(latDegrees)
        record.positionLong = semicircles(lonDegrees)
        record.distance = UInt32(distanceMeters * 100)
        return record
    }

    private static func semicircles(_ degrees: Double) -> Int32 {
        Int32((degrees * pow(2, 31) / 180).rounded())
    }

    // MARK: - Compressed Timestamp Tests

    func testCompressedTimestampParsesCorrectly() throws {
        // Build a FIT file with: definition, baseline record, compressed-timestamp record
        var content = Data()
        // Definition for local type 0: record with 4 fields (same as writeDefinition)
        Self.writeDefinition(to: &content)

        // Baseline record (local type 0, normal header)
        let baselineTimestamp: UInt32 = 1_000_000
        content.append(0x00) // normal data message, local type 0
        Self.append(baselineTimestamp, to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content) // distance

        // Compressed timestamp record: bit 7=1, bits 5-6=local type (0), bits 0-4=time offset (10)
        let compressedHeader: UInt8 = 0x80 | (0 << 5) | 10 // local type 0, offset 10
        content.append(compressedHeader)
        Self.append(Self.semicircles(37.7750), to: &content)
        Self.append(Self.semicircles(-122.4195), to: &content)
        Self.append(UInt32(2000), to: &content) // distance

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.records.count, 2)
        XCTAssertEqual(decoded.records[0].timestamp, baselineTimestamp)
        XCTAssertEqual(decoded.records[1].timestamp, baselineTimestamp + 10)
    }

    func testCompressedTimestampWrapHandling() throws {
        var content = Data()
        Self.writeDefinition(to: &content)

        // Baseline record near the top of the 5-bit window
        let baselineTimestamp: UInt32 = 1_000_030
        content.append(0x00)
        Self.append(baselineTimestamp, to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)

        // Compressed timestamp with offset 5 — wraps past 32
        let compressedHeader: UInt8 = 0x80 | (0 << 5) | 5
        content.append(compressedHeader)
        Self.append(Self.semicircles(37.7750), to: &content)
        Self.append(Self.semicircles(-122.4195), to: &content)
        Self.append(UInt32(1000), to: &content)

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.records.count, 2)
        // lastTimestamp & 0x1F = 30, timeOffset = 5
        // offsetDelta = (5 &- 30) & 0x1F = 7 (masked to 5 bits)
        // timestamp = 1000030 + 7 = 1000037
        XCTAssertEqual(decoded.records[1].timestamp, baselineTimestamp &+ ((5 &- 30) & 0x1F))
    }

    func testCompressedTimestampWithMultipleLocalTypes() throws {
        // Two definitions: local 0 = record, local 1 = event
        var content = Data()

        // Definition for local type 0: record message (global 20)
        content.append(0x40) // definition, local type 0
        content.append(0x00) // reserved
        content.append(0x00) // little-endian
        content.append(contentsOf: [0x14, 0x00]) // global msg 20 (record)
        content.append(2) // 2 fields
        Self.writeField(253, size: 4, type: 134, to: &content) // timestamp
        Self.writeField(0, size: 4, type: 133, to: &content)   // position_lat

        // Definition for local type 1: event message (global 21)
        content.append(0x41) // definition, local type 1
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x15, 0x00]) // global msg 21 (event)
        content.append(3) // 3 fields
        Self.writeField(253, size: 4, type: 134, to: &content) // timestamp
        Self.writeField(0, size: 1, type: 2, to: &content)     // event
        Self.writeField(1, size: 1, type: 2, to: &content)     // event_type

        // Baseline record (local type 0)
        let baselineTimestamp: UInt32 = 500_000
        content.append(0x00)
        Self.append(baselineTimestamp, to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)

        // Compressed timestamp for local type 1 (event), offset 5
        let compressedHeader: UInt8 = 0x80 | (1 << 5) | 5 // local type 1, offset 5
        content.append(compressedHeader)
        content.append(0) // event = timer
        content.append(0) // event_type = start

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events[0].timestamp, baselineTimestamp + 5)
    }

    func testCompressedSessionRetainsReconstructedTimestamp() throws {
        var content = Data()

        // Local type 0 establishes the compressed-timestamp baseline.
        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x14, 0x00]) // record
        content.append(2)
        Self.writeField(253, size: 4, type: 134, to: &content)
        Self.writeField(0, size: 4, type: 133, to: &content)

        // Local type 1 is a session whose timestamp will be compressed.
        content.append(0x41)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x12, 0x00]) // session
        content.append(3)
        Self.writeField(253, size: 4, type: 134, to: &content)
        Self.writeField(2, size: 4, type: 134, to: &content)
        Self.writeField(5, size: 1, type: 2, to: &content)

        let baselineTimestamp: UInt32 = 1_000
        content.append(0x00)
        Self.append(baselineTimestamp, to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)

        // Baseline's low five bits are 8, so offset 18 reconstructs +10 seconds.
        content.append(0x80 | (1 << 5) | 18)
        Self.append(UInt32(900), to: &content)
        content.append(FITSport.running.rawValue)

        let decoded = try FITParser.parse(data: Self.fitData(rawContent: content))

        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions[0].timestamp, 1_010)
        XCTAssertEqual(decoded.sessions[0].startTime, 900)
        XCTAssertEqual(decoded.sessions[0].sport, FITSport.running.rawValue)
        guard case .session(let session) = decoded.orderedMessages.last else {
            return XCTFail("Expected compressed session to be retained in source order")
        }
        XCTAssertEqual(session.timestamp, 1_010)
    }

    func testCompressedHeaderRejectsDefinitionWithoutLeadingTimestamp() {
        var content = Data()

        // Local type 0 establishes a timestamp baseline.
        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x14, 0x00])
        content.append(2)
        Self.writeField(253, size: 4, type: 134, to: &content)
        Self.writeField(0, size: 4, type: 133, to: &content)

        // Local type 1 has no timestamp field and cannot use a compressed header.
        content.append(0x41)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x15, 0x00])
        content.append(1)
        Self.writeField(0, size: 1, type: 2, to: &content)

        content.append(0x00)
        Self.append(UInt32(1_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)

        content.append(0x80 | (1 << 5) | 10)

        XCTAssertThrowsError(try FITParser.parse(data: Self.fitData(rawContent: content))) { error in
            guard case FITError.invalidCompressedDefinition = error else {
                return XCTFail("Expected invalidCompressedDefinition, got \(error)")
            }
        }
    }

    // MARK: - Multi-Message Type Tests

    func testFileIDMessageIsParsed() throws {
        var content = Data()

        // Definition for file_id (global 0): 3 fields
        content.append(0x40) // definition, local type 0
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x00, 0x00]) // global msg 0 (file_id)
        content.append(3)
        Self.writeField(0, size: 1, type: 2, to: &content)   // type (uint8)
        Self.writeField(1, size: 2, type: 132, to: &content)  // manufacturer (uint16)
        Self.writeField(4, size: 4, type: 134, to: &content)  // time_created (uint32)

        // Data message
        content.append(0x00)
        content.append(4) // type = activity
        let manufacturer: UInt16 = 1 // Garmin
        content.append(contentsOf: withUnsafeBytes(of: manufacturer.littleEndian) { Array($0) })
        let timeCreated: UInt32 = 1_000_000
        content.append(contentsOf: withUnsafeBytes(of: timeCreated.littleEndian) { Array($0) })

        // Also add a record definition + record so the file isn't empty
        Self.writeDefinition(to: &content)
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertNotNil(decoded.fileID)
        XCTAssertEqual(decoded.fileID?.type, 4)
        XCTAssertEqual(decoded.fileID?.manufacturer, 1)
        XCTAssertEqual(decoded.fileID?.timeCreated, timeCreated)
    }

    func testSessionMessageIsParsed() throws {
        var content = Data()

        // Definition for session (global 18): key fields
        content.append(0x40) // definition, local type 0
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x12, 0x00]) // global msg 18 (session)
        content.append(4)
        Self.writeField(253, size: 4, type: 134, to: &content) // timestamp
        Self.writeField(5, size: 1, type: 2, to: &content)     // sport
        Self.writeField(6, size: 1, type: 2, to: &content)     // sub_sport
        Self.writeField(9, size: 4, type: 134, to: &content)   // total_distance

        // Session data
        content.append(0x00)
        Self.append(UInt32(1_000_100), to: &content) // timestamp
        content.append(1)  // sport = running
        content.append(0)  // sub_sport = generic
        Self.append(UInt32(500000), to: &content) // total_distance (5000m * 100)

        // Record definition + record
        Self.writeDefinition(to: &content)
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions[0].sport, 1) // running
        XCTAssertEqual(decoded.sessions[0].subSport, 0)
        XCTAssertEqual(decoded.sessions[0].totalDistance, 500000)
    }

    func testEventMessageIsParsed() throws {
        var content = Data()

        // Definition for event (global 21)
        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x15, 0x00]) // global msg 21 (event)
        content.append(4)
        Self.writeField(253, size: 4, type: 134, to: &content) // timestamp
        Self.writeField(0, size: 1, type: 2, to: &content)     // event
        Self.writeField(1, size: 1, type: 2, to: &content)     // event_type
        Self.writeField(2, size: 1, type: 2, to: &content)     // event_group

        // Timer start event
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        content.append(0)  // event = timer
        content.append(0)  // event_type = start
        content.append(0)  // event_group

        // Record definition + record
        Self.writeDefinition(to: &content)
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertEqual(decoded.events[0].event, 0) // timer
        XCTAssertEqual(decoded.events[0].eventType, 0) // start
        XCTAssertEqual(decoded.events[0].timerEventType, .start)
    }

    func testActivityMessageAndSourceOrderAreRetained() throws {
        var content = Data()

        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x22, 0x00]) // global msg 34 (activity)
        content.append(4)
        Self.writeField(253, size: 4, type: 134, to: &content)
        Self.writeField(0, size: 4, type: 134, to: &content)
        Self.writeField(2, size: 2, type: 132, to: &content)
        Self.writeField(3, size: 1, type: 0, to: &content)

        content.append(0x00)
        Self.append(UInt32(1_000_100), to: &content)
        Self.append(UInt32(60_000), to: &content)
        let sessionCount: UInt16 = 1
        content.append(contentsOf: withUnsafeBytes(of: sessionCount.littleEndian) { Array($0) })
        content.append(0) // manual activity type

        Self.writeDefinition(to: &content)
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)

        let decoded = try FITParser.parse(data: Self.fitData(rawContent: content))

        XCTAssertEqual(decoded.activities.count, 1)
        XCTAssertEqual(decoded.activities[0].timestamp, 1_000_100)
        XCTAssertEqual(decoded.activities[0].totalTimerTime, 60_000)
        XCTAssertEqual(decoded.activities[0].numSessions, 1)
        XCTAssertEqual(decoded.orderedMessages.count, 2)
        guard case .activity = decoded.orderedMessages[0],
              case .record = decoded.orderedMessages[1]
        else {
            return XCTFail("Expected activity then record source order")
        }
    }

    func testDeviceInfoMessageIsParsed() throws {
        var content = Data()

        // Definition for device_info (global 23), using official profile fields.
        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x17, 0x00]) // global msg 23 (device_info)
        content.append(9)
        Self.writeField(253, size: 4, type: 134, to: &content) // timestamp
        Self.writeField(0, size: 1, type: 2, to: &content)     // device_index
        Self.writeField(1, size: 1, type: 2, to: &content)     // device_type
        Self.writeField(2, size: 2, type: 132, to: &content)   // manufacturer
        Self.writeField(3, size: 4, type: 140, to: &content)   // serial_number (uint32z)
        Self.writeField(4, size: 2, type: 132, to: &content)   // product
        Self.writeField(5, size: 2, type: 132, to: &content)   // software_version
        Self.writeField(6, size: 1, type: 2, to: &content)     // hardware_version
        Self.writeField(27, size: 10, type: 7, to: &content)   // product_name

        // Device info data
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        content.append(0) // device index
        content.append(1) // device type
        let manufacturer: UInt16 = 1 // Garmin
        content.append(contentsOf: withUnsafeBytes(of: manufacturer.littleEndian) { Array($0) })
        Self.append(UInt32(123_456), to: &content)
        let product: UInt16 = 3111
        content.append(contentsOf: withUnsafeBytes(of: product.littleEndian) { Array($0) })
        let softwareVersion: UInt16 = 123
        content.append(contentsOf: withUnsafeBytes(of: softwareVersion.littleEndian) { Array($0) })
        content.append(7) // hardware version
        content.append(contentsOf: Array("Forerunner".utf8))

        // Record
        Self.writeDefinition(to: &content)
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.deviceInfo.count, 1)
        XCTAssertEqual(decoded.deviceInfo[0].deviceIndex, 0)
        XCTAssertEqual(decoded.deviceInfo[0].deviceType, 1)
        XCTAssertEqual(decoded.deviceInfo[0].manufacturer, 1)
        XCTAssertEqual(decoded.deviceInfo[0].serialNumber, 123_456)
        XCTAssertEqual(decoded.deviceInfo[0].product, 3111)
        XCTAssertEqual(decoded.deviceInfo[0].softwareVersion, 123)
        XCTAssertEqual(decoded.deviceInfo[0].hardwareVersion, 7)
        XCTAssertEqual(decoded.deviceInfo[0].productName, "Forerunner")
    }

    func testLapMessageUsesOfficialProfileFieldNumbers() throws {
        var content = Data()
        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x13, 0x00]) // global msg 19 (lap)
        content.append(5)
        Self.writeField(21, size: 2, type: 132, to: &content) // total_ascent
        Self.writeField(22, size: 2, type: 132, to: &content) // total_descent
        Self.writeField(24, size: 1, type: 0, to: &content)   // lap_trigger
        Self.writeField(25, size: 1, type: 0, to: &content)   // sport
        Self.writeField(26, size: 1, type: 2, to: &content)   // event_group

        content.append(0x00)
        let ascent: UInt16 = 432
        let descent: UInt16 = 123
        content.append(contentsOf: withUnsafeBytes(of: ascent.littleEndian) { Array($0) })
        content.append(contentsOf: withUnsafeBytes(of: descent.littleEndian) { Array($0) })
        content.append(2)
        content.append(FITSport.running.rawValue)
        content.append(4)

        let decoded = try FITParser.parse(data: Self.fitData(rawContent: content))

        XCTAssertEqual(decoded.laps.count, 1)
        XCTAssertEqual(decoded.laps[0].totalAscent, ascent)
        XCTAssertEqual(decoded.laps[0].totalDescent, descent)
        XCTAssertEqual(decoded.laps[0].lapTrigger, 2)
        XCTAssertEqual(decoded.laps[0].sport, FITSport.running.rawValue)
        XCTAssertEqual(decoded.laps[0].eventGroup, 4)
    }

    func testSessionMessageUsesOfficialProfileFieldNumbers() throws {
        var content = Data()
        content.append(0x40)
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x12, 0x00]) // global msg 18 (session)
        content.append(6)
        Self.writeField(23, size: 2, type: 132, to: &content) // total_descent
        Self.writeField(27, size: 1, type: 2, to: &content)   // event_group
        Self.writeField(28, size: 1, type: 0, to: &content)   // trigger
        Self.writeField(29, size: 4, type: 133, to: &content) // nec_lat
        Self.writeField(30, size: 4, type: 133, to: &content) // nec_long
        Self.writeField(31, size: 4, type: 133, to: &content) // swc_lat

        content.append(0x00)
        let descent: UInt16 = 321
        content.append(contentsOf: withUnsafeBytes(of: descent.littleEndian) { Array($0) })
        content.append(3)
        content.append(1)
        Self.append(Self.semicircles(40.0), to: &content)
        Self.append(Self.semicircles(-75.0), to: &content)
        Self.append(Self.semicircles(39.0), to: &content)

        let decoded = try FITParser.parse(data: Self.fitData(rawContent: content))

        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions[0].totalDescent, descent)
        XCTAssertEqual(decoded.sessions[0].eventGroup, 3)
        XCTAssertEqual(decoded.sessions[0].trigger, 1)
        XCTAssertEqual(decoded.sessions[0].necLat, Self.semicircles(40.0))
        XCTAssertEqual(decoded.sessions[0].necLong, Self.semicircles(-75.0))
        XCTAssertEqual(decoded.sessions[0].swcLat, Self.semicircles(39.0))
    }

    // MARK: - Enhanced Metrics Tests

    func testEnhancedAltitudeAndSpeedAreParsed() throws {
        var content = Data()

        // Definition with enhanced altitude (field 78) and enhanced speed (field 73)
        content.append(0x40) // definition, local type 0
        content.append(0x00)
        content.append(0x00)
        content.append(contentsOf: [0x14, 0x00]) // global msg 20 (record)
        content.append(6)
        Self.writeField(253, size: 4, type: 134, to: &content) // timestamp (uint32)
        Self.writeField(0, size: 4, type: 133, to: &content)   // position_lat (sint32)
        Self.writeField(1, size: 4, type: 133, to: &content)   // position_long (sint32)
        Self.writeField(5, size: 4, type: 134, to: &content)   // distance (uint32)
        Self.writeField(78, size: 4, type: 134, to: &content)  // enhanced_altitude (uint32)
        Self.writeField(73, size: 4, type: 134, to: &content)  // enhanced_speed (uint32)

        // Values exceed UInt16 so this catches any accidental truncation of the
        // profile-defined UInt32 enhanced fields.
        content.append(0x00)
        Self.append(UInt32(1_000_000), to: &content)
        Self.append(Self.semicircles(37.7749), to: &content)
        Self.append(Self.semicircles(-122.4194), to: &content)
        Self.append(UInt32(0), to: &content)
        Self.append(UInt32(100_000), to: &content) // enhanced_altitude
        Self.append(UInt32(200_000), to: &content) // enhanced_speed

        let data = Self.fitData(rawContent: content)
        let decoded = try FITParser.parse(data: data)

        XCTAssertEqual(decoded.records.count, 1)
        XCTAssertEqual(decoded.records[0].enhancedAltitude, 100_000)
        XCTAssertEqual(decoded.records[0].enhancedSpeed, 200_000)

        // Verify the decoder uses enhanced values
        let points = FITDecoder.decode(records: decoded.records)
        XCTAssertEqual(points.count, 1)
        // enhanced altitude: (100000 / 5.0) - 500 = 19500.0
        XCTAssertEqual(points[0].altitudeMeters ?? 0, 19_500.0, accuracy: 0.01)
        // enhanced speed: 200000 / 1000.0 = 200.0
        XCTAssertEqual(points[0].speedMetersPerSecond ?? 0, 200.0, accuracy: 0.01)
    }

    func testInvalidEnhancedMetricFallsBackToLegacyValue() {
        var record = Self.record(
            timestamp: 1_000,
            latDegrees: 37.7749,
            lonDegrees: -122.4194,
            distanceMeters: 0
        )
        record.enhancedAltitude = FITParser.invalidUint32
        record.altitude = 2_550 // 10m
        record.enhancedSpeed = FITParser.invalidUint32
        record.speed = 3_500 // 3.5m/s

        let points = FITDecoder.decode(records: [record])

        XCTAssertEqual(points[0].altitudeMeters, 10.0)
        XCTAssertEqual(points[0].speedMetersPerSecond, 3.5)
    }

    // MARK: - Session Selection Tests

    func testSessionSelectionWithSingleRunningSession() throws {
        var decodedFile = FITDecodedFile()

        // Add a running session with GPS coordinates
        var session = FITSessionMessage()
        session.sport = FITSport.running.rawValue
        session.startPositionLat = Self.semicircles(37.7749)
        session.startPositionLong = Self.semicircles(-122.4194)
        session.startTime = 1_000_000
        session.timestamp = 1_000_100
        decodedFile.sessions = [session]

        // Add records within the session timeframe
        for i in 0..<5 {
            var record = FITRecordMessage()
            record.timestamp = UInt32(1_000_000 + i * 20)
            record.positionLat = Self.semicircles(37.7749 + Double(i) * 0.0001)
            record.positionLong = Self.semicircles(-122.4194 + Double(i) * 0.0001)
            record.distance = UInt32(i * 1000)
            decodedFile.records.append(record)
        }

        let points = try FITDecoder.decode(decodedFile: decodedFile)
        XCTAssertEqual(points.count, 5)
    }

    func testSessionAssociationDerivesStartTimeFromElapsedDuration() throws {
        var decodedFile = FITDecodedFile()
        var session = FITSessionMessage()
        session.sport = FITSport.running.rawValue
        session.startPositionLat = Self.semicircles(37.7749)
        session.startPositionLong = Self.semicircles(-122.4194)
        session.timestamp = 1_000_100
        session.totalElapsedTime = 100_000 // milliseconds
        decodedFile.sessions = [session]

        decodedFile.records = [
            Self.record(timestamp: 1_000_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            Self.record(timestamp: 1_000_100, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20),
            Self.record(timestamp: 1_000_101, latDegrees: 37.7751, lonDegrees: -122.4196, distanceMeters: 40)
        ]

        let points = try FITDecoder.decode(decodedFile: decodedFile)

        XCTAssertEqual(points.count, 2)
    }

    func testSessionSelectionRejectsMultipleRunningSessions() throws {
        var decodedFile = FITDecodedFile()

        for _ in 0..<2 {
            var session = FITSessionMessage()
            session.sport = FITSport.running.rawValue
            session.startPositionLat = Self.semicircles(37.7749)
            session.startPositionLong = Self.semicircles(-122.4194)
            decodedFile.sessions.append(session)
        }

        decodedFile.records = [FITRecordMessage()]

        XCTAssertThrowsError(try FITDecoder.decode(decodedFile: decodedFile)) { error in
            guard case WorkoutImportError.parsingError(let message) = error else {
                XCTFail("Expected parsingError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("2 runs"))
        }
    }

    func testSessionSelectionRejectsNonRunningSport() throws {
        var decodedFile = FITDecodedFile()

        var session = FITSessionMessage()
        session.sport = FITSport.cycling.rawValue
        session.startPositionLat = Self.semicircles(37.7749)
        session.startPositionLong = Self.semicircles(-122.4194)
        decodedFile.sessions = [session]

        decodedFile.records = [FITRecordMessage()]

        XCTAssertThrowsError(try FITDecoder.decode(decodedFile: decodedFile)) { error in
            guard case WorkoutImportError.parsingError(let message) = error else {
                XCTFail("Expected parsingError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Only running workouts"))
        }
    }

    func testSessionSelectionRejectsHikingSport() throws {
        var decodedFile = FITDecodedFile()

        var session = FITSessionMessage()
        session.sport = FITSport.hiking.rawValue
        session.startPositionLat = Self.semicircles(37.7749)
        session.startPositionLong = Self.semicircles(-122.4194)
        decodedFile.sessions = [session]

        XCTAssertThrowsError(try FITDecoder.decode(decodedFile: decodedFile)) { error in
            guard case WorkoutImportError.parsingError(let message) = error else {
                return XCTFail("Expected parsingError, got \(error)")
            }
            XCTAssertTrue(message.contains("Only running workouts"))
        }
    }

    func testSessionSelectionFallsBackWithoutSessions() throws {
        var decodedFile = FITDecodedFile()
        // No sessions — should fall back to legacy

        var record = FITRecordMessage()
        record.timestamp = 1_000_000
        record.positionLat = Self.semicircles(37.7749)
        record.positionLong = Self.semicircles(-122.4194)
        record.distance = 0
        decodedFile.records = [record]

        let points = try FITDecoder.decode(decodedFile: decodedFile)
        XCTAssertEqual(points.count, 1)
    }

    // MARK: - Timer Event Segmentation Tests

    func testTimerEventSegmentationSplitsRoute() throws {
        var decodedFile = FITDecodedFile()

        // Running session
        var session = FITSessionMessage()
        session.sport = FITSport.running.rawValue
        session.startPositionLat = Self.semicircles(37.7749)
        session.startPositionLong = Self.semicircles(-122.4194)
        session.startTime = 1_000_000
        session.timestamp = 1_000_120
        decodedFile.sessions = [session]

        // Timer start at t=1000000
        var event1 = FITEventMessage()
        event1.timestamp = 1_000_000
        event1.event = 0 // timer
        event1.eventType = 0 // start
        decodedFile.events.append(event1)

        // Timer stop at t=1000040
        var event2 = FITEventMessage()
        event2.timestamp = 1_000_040
        event2.event = 0 // timer
        event2.eventType = 1 // stop
        decodedFile.events.append(event2)

        // Timer start at t=1000080 (resume)
        var event3 = FITEventMessage()
        event3.timestamp = 1_000_080
        event3.event = 0 // timer
        event3.eventType = 0 // start
        decodedFile.events.append(event3)

        // 6 records spanning the full session
        for i in 0..<6 {
            var record = FITRecordMessage()
            record.timestamp = UInt32(1_000_000 + i * 20)
            record.positionLat = Self.semicircles(37.7749 + Double(i) * 0.0001)
            record.positionLong = Self.semicircles(-122.4194 + Double(i) * 0.0001)
            record.distance = UInt32(i * 1000)
            decodedFile.records.append(record)
        }

        let points = try FITDecoder.decode(decodedFile: decodedFile)
        // The record collected during the paused interval is excluded, and the
        // resumed route starts a new segment without a geographic distance jump.
        XCTAssertEqual(points.count, 5)
        XCTAssertEqual(points.map(\.routeSegmentIndex), [0, 0, 0, 1, 1])
        XCTAssertEqual(
            points[3].distanceFromStartMeters,
            points[2].distanceFromStartMeters,
            accuracy: 0.001
        )

        var workout = RunWorkout(routePoints: points)
        WorkoutAnalyzer().analyze(&workout)
        XCTAssertEqual(workout.summary.totalElapsedSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalActiveSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(workout.summary.totalPausedSeconds, 40, accuracy: 0.001)
    }

    // MARK: - Ordered Messages Test

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func append(_ value: Int32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
}
