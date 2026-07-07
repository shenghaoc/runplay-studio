import XCTest
@testable import RunPlayCore

final class FITParserTests: XCTestCase {

    func testNegativeFITCoordinatesUseBitPatternSemantics() throws {
        let data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            (timestamp: 1_010, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
        ])

        let records = try FITParser.parse(data: data)
        let points = FITDecoder.decode(records: records)

        XCTAssertEqual(points.count, 2)
        XCTAssertGreaterThan(points[0].latitude, 0)
        XCTAssertLessThan(points[0].longitude, 0)
        XCTAssertGreaterThan(points[1].distanceFromStartMeters, points[0].distanceFromStartMeters)
    }

    func testCompressedTimestampHeaderFailsWithoutDesyncing() {
        let data = Self.fitData(rawContent: Data([0x80]))

        XCTAssertThrowsError(try FITParser.parse(data: data)) { error in
            guard case FITError.corruptedData(let message) = error else {
                XCTFail("Expected corruptedData, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Compressed timestamp"))
        }
    }

    func testValidCRCParsesSuccessfully() throws {
        let data = Self.fitData(records: [
            (timestamp: 1_000, latDegrees: 37.7749, lonDegrees: -122.4194, distanceMeters: 0),
            (timestamp: 1_010, latDegrees: 37.7750, lonDegrees: -122.4195, distanceMeters: 20)
        ])

        // Should not throw — CRCs are valid
        let records = try FITParser.parse(data: data)
        XCTAssertEqual(records.count, 2)
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

        let records = try FITParser.parse(data: data)
        let points = FITDecoder.decode(records: records)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(points.count, 2)
        XCTAssertGreaterThan(points[1].distanceFromStartMeters, points[0].distanceFromStartMeters)
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
        records: [(timestamp: UInt32, latDegrees: Double, lonDegrees: Double, distanceMeters: Double)]
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
        return fitData(rawContent: content)
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

    private static func fitData(rawContent content: Data) -> Data {
        var data = Data()
        data.append(14)
        data.append(16)
        data.append(contentsOf: [0x40, 0x01])
        append(UInt32(content.count), to: &data)
        data.append(contentsOf: [0x46, 0x49, 0x54, 0x20])
        // Placeholder header CRC — will be patched below
        data.append(contentsOf: [0x00, 0x00])
        // Patch header CRC (covers bytes 0..<12)
        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)
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

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func append(_ value: Int32, to data: inout Data) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
}
