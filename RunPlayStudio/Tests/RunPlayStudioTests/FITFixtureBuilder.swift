import Foundation
import RunPlayCore

/// Builds minimal FIT binary data for testing.
///
/// Creates valid FIT files with record messages containing
/// GPS, altitude, heart rate, and cadence data.
struct FITFixtureBuilder {

    /// Build a minimal FIT file with running activity data.
    static func buildSampleRun() -> Data {
        var data = Data()

        // Build data content first to calculate size
        var content = Data()

        // Write definition message for record type
        writeDefinitionMessage(to: &content)

        // Write record messages
        let recordCount = 30
        for i in 0..<recordCount {
            writeRecordMessage(to: &content, index: i, total: recordCount)
        }

        // Write header
        writeHeader(to: &data, dataSize: UInt32(content.count))

        // Append content
        data.append(content)

        // Write CRC (simplified - just zeros for testing)
        data.append(contentsOf: [0x00, 0x00])

        return data
    }

    /// Build a FIT file with invalid header.
    static func buildInvalidHeader() -> Data {
        var data = Data()
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                 0xFF, 0xFF])
        return data
    }

    /// Build a FIT file with invalid data type.
    static func buildInvalidDataType() -> Data {
        var data = Data()
        data.append(14) // header length
        data.append(16) // protocol version
        data.append(contentsOf: [0x00, 0x00]) // profile version
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // data size
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Invalid data type
        data.append(contentsOf: [0x00, 0x00]) // CRC
        return data
    }

    // MARK: - Private Helpers

    private static func writeHeader(to data: inout Data, dataSize: UInt32) {
        data.append(14) // header length
        data.append(16) // protocol version
        data.append(contentsOf: [0x40, 0x01]) // profile version (little-endian)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x46, 0x49, 0x54, 0x20]) // "FIT "
        data.append(contentsOf: [0x00, 0x00]) // header CRC
    }

    private static func writeDefinitionMessage(to data: inout Data) {
        // Record header: definition message for local type 0
        data.append(0x40) // bit 6=1 (definition), local type=0

        // Definition message content
        data.append(0x00) // reserved
        data.append(0x00) // architecture: little-endian

        // Global message number: 20 (Record)
        data.append(contentsOf: [0x14, 0x00])

        // Number of fields: 8
        data.append(8)

        // Field definitions
        // timestamp (field 253, size 4, type 134 = uint32)
        writeFieldDef(field: 253, size: 4, type: 134, to: &data)

        // position_lat (field 0, size 4, type 133 = int32)
        writeFieldDef(field: 0, size: 4, type: 133, to: &data)

        // position_long (field 1, size 4, type 133 = int32)
        writeFieldDef(field: 1, size: 4, type: 133, to: &data)

        // altitude (field 2, size 2, type 132 = uint16)
        writeFieldDef(field: 2, size: 2, type: 132, to: &data)

        // distance (field 5, size 4, type 134 = uint32)
        writeFieldDef(field: 5, size: 4, type: 134, to: &data)

        // speed (field 6, size 2, type 132 = uint16)
        writeFieldDef(field: 6, size: 2, type: 132, to: &data)

        // heart_rate (field 3, size 1, type 2 = uint8)
        writeFieldDef(field: 3, size: 1, type: 2, to: &data)

        // cadence (field 4, size 1, type 2 = uint8)
        writeFieldDef(field: 4, size: 1, type: 2, to: &data)
    }

    private static func writeFieldDef(field: UInt8, size: UInt8, type: UInt8, to data: inout Data) {
        data.append(field)
        data.append(size)
        data.append(type)
    }

    private static func writeRecordMessage(to data: inout Data, index: Int, total: Int) {
        // Record header: data message for local type 0
        data.append(0x00)

        let fraction = Double(index) / Double(total - 1)

        // timestamp (uint32, seconds from FIT epoch)
        let baseTimestamp: UInt32 = 1000000000 // Some arbitrary FIT timestamp
        let timestamp = baseTimestamp + UInt32(index * 10) // 10 second intervals
        data.append(contentsOf: withUnsafeBytes(of: timestamp.littleEndian) { Array($0) })

        // position_lat (int32, semicircles)
        // Singapore area: ~1.3 degrees = ~1.3 * (2^31 / 180) semicircles
        let baseLat: Int32 = 12780237 // ~1.06 degrees in semicircles
        let latOffset = Int32(fraction * 500000) // Move ~0.04 degrees over the run
        let lat = baseLat + latOffset
        data.append(contentsOf: withUnsafeBytes(of: lat.littleEndian) { Array($0) })

        // position_long (int32, semicircles)
        // Singapore area: ~103.8 degrees
        let baseLon: Int32 = 1241516163 // ~103.5 degrees in semicircles
        let lonOffset = Int32(fraction * 500000)
        let lon = baseLon + lonOffset
        data.append(contentsOf: withUnsafeBytes(of: lon.littleEndian) { Array($0) })

        // altitude (uint16, scaled: value = (meters + 500) * 5)
        let altitudeMeters = 15.0 + fraction * 30 // 15m to 45m
        let altScaled = UInt16((altitudeMeters + 500) * 5)
        data.append(contentsOf: withUnsafeBytes(of: altScaled.littleEndian) { Array($0) })

        // distance (uint32, scaled: value = meters * 100)
        let distanceMeters = fraction * 5000 // 0 to 5km
        let distScaled = UInt32(distanceMeters * 100)
        data.append(contentsOf: withUnsafeBytes(of: distScaled.littleEndian) { Array($0) })

        // speed (uint16, scaled: value = m/s * 1000)
        let speedMPS = 3.0 + Double(index % 5) * 0.2 // Varies 3.0-4.0 m/s
        let speedScaled = UInt16(speedMPS * 1000)
        data.append(contentsOf: withUnsafeBytes(of: speedScaled.littleEndian) { Array($0) })

        // heart_rate (uint8, bpm)
        let hr = UInt8(120 + Int(fraction * 50)) // 120-170 bpm
        data.append(hr)

        // cadence (uint8, rpm)
        let cad = UInt8(80 + Int(fraction * 15)) // 80-95 rpm
        data.append(cad)
    }
}
