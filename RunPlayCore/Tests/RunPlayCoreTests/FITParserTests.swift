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

    private static func fitData(rawContent content: Data) -> Data {
        var data = Data()
        data.append(14)
        data.append(16)
        data.append(contentsOf: [0x40, 0x01])
        append(UInt32(content.count), to: &data)
        data.append(contentsOf: [0x46, 0x49, 0x54, 0x20])
        data.append(contentsOf: [0x00, 0x00])
        data.append(content)
        data.append(contentsOf: [0x00, 0x00])
        return data
    }

    private static func writeDefinition(to data: inout Data) {
        data.append(0x40)
        data.append(0x00)
        data.append(0x00)
        data.append(contentsOf: [0x14, 0x00])
        data.append(4)
        writeField(253, size: 4, type: 134, to: &data)
        writeField(0, size: 4, type: 133, to: &data)
        writeField(1, size: 4, type: 133, to: &data)
        writeField(5, size: 4, type: 134, to: &data)
    }

    private static func writeField(_ number: UInt8, size: UInt8, type: UInt8, to data: inout Data) {
        data.append(number)
        data.append(size)
        data.append(type)
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
