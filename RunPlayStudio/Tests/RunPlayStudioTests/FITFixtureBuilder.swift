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

        // Write header (with placeholder CRC)
        writeHeader(to: &data, dataSize: UInt32(content.count))

        // Compute and patch header CRC
        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)

        // Append content
        data.append(content)

        // Compute and write file CRC
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))

        return data
    }

    /// Build the same route with one selected running session whose elapsed
    /// and timer totals can validate (or intentionally disagree with) the
    /// route-derived clocks.
    static func buildSampleRunWithSession(
        elapsedSeconds: UInt32,
        timerSeconds: UInt32
    ) -> Data {
        var content = Data()
        writeDefinitionMessage(to: &content)

        let recordCount = 30
        for index in 0..<recordCount {
            writeRecordMessage(to: &content, index: index, total: recordCount)
        }
        writeSessionDefinitionMessage(to: &content)
        writeSessionMessage(
            elapsedSeconds: elapsedSeconds,
            timerSeconds: timerSeconds,
            numberOfLaps: 0,
            to: &content
        )

        var data = Data()
        writeHeader(to: &data, dataSize: UInt32(content.count))
        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)
        data.append(content)
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))
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

    /// Build a sample run with one session and two lap messages (manual + distance).
    static func buildSampleRunWithLaps() -> Data {
        var content = Data()
        writeDefinitionMessage(to: &content)

        let recordCount = 30
        for index in 0..<recordCount {
            writeRecordMessage(to: &content, index: index, total: recordCount)
        }

        writeSessionDefinitionMessage(to: &content)
        writeSessionMessage(
            elapsedSeconds: 290,
            timerSeconds: 290,
            numberOfLaps: 2,
            to: &content
        )

        writeLapDefinitionMessage(to: &content)
        // Lap 1: first half, manual trigger
        writeLapMessage(
            messageIndex: 0,
            startOffset: 0,
            endOffset: 140,
            elapsedSeconds: 140,
            timerSeconds: 140,
            distanceMeters: 2_500,
            calories: 180,
            trigger: 0,
            to: &content
        )
        // Lap 2: second half, distance trigger
        writeLapMessage(
            messageIndex: 1,
            startOffset: 140,
            endOffset: 290,
            elapsedSeconds: 150,
            timerSeconds: 150,
            distanceMeters: 2_500,
            calories: 190,
            trigger: 2,
            to: &content
        )

        var data = Data()
        writeHeader(to: &data, dataSize: UInt32(content.count))
        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)
        data.append(content)
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))
        return data
    }

    /// Build a valid route with one selected-session lap whose start and totals
    /// cannot establish a safe boundary. Import should keep the route and report
    /// the skipped malformed lap.
    static func buildSampleRunWithMalformedLap() -> Data {
        var content = Data()
        writeDefinitionMessage(to: &content)

        let recordCount = 30
        for index in 0..<recordCount {
            writeRecordMessage(to: &content, index: index, total: recordCount)
        }

        writeSessionDefinitionMessage(to: &content)
        writeSessionMessage(
            elapsedSeconds: 290,
            timerSeconds: 290,
            numberOfLaps: 1,
            to: &content
        )
        writeLapDefinitionMessage(to: &content)
        writeMalformedLapMessage(to: &content)

        var data = Data()
        writeHeader(to: &data, dataSize: UInt32(content.count))
        let headerCRC = FITParser.crc16(over: data[0..<12])
        data[12] = UInt8(headerCRC & 0xFF)
        data[13] = UInt8(headerCRC >> 8)
        data.append(content)
        let fileCRC = FITParser.crc16(over: data)
        data.append(UInt8(fileCRC & 0xFF))
        data.append(UInt8(fileCRC >> 8))
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

    private static func writeSessionDefinitionMessage(to data: inout Data) {
        data.append(0x41) // definition, local type 1
        data.append(0x00) // reserved
        data.append(0x00) // little-endian
        data.append(contentsOf: [0x12, 0x00]) // global message 18 (session)
        data.append(7)
        writeFieldDef(field: 253, size: 4, type: 134, to: &data) // timestamp
        writeFieldDef(field: 2, size: 4, type: 134, to: &data)   // start_time
        writeFieldDef(field: 5, size: 1, type: 2, to: &data)     // sport
        writeFieldDef(field: 7, size: 4, type: 134, to: &data)   // total_elapsed_time
        writeFieldDef(field: 8, size: 4, type: 134, to: &data)   // total_timer_time
        writeFieldDef(field: 25, size: 2, type: 132, to: &data)  // first_lap_index
        writeFieldDef(field: 26, size: 2, type: 132, to: &data)  // num_laps
    }

    private static func writeSessionMessage(
        elapsedSeconds: UInt32,
        timerSeconds: UInt32,
        numberOfLaps: UInt16,
        to data: inout Data
    ) {
        let baseTimestamp: UInt32 = 1_000_000_000
        data.append(0x01) // data message, local type 1
        data.append(contentsOf: withUnsafeBytes(of: (baseTimestamp + 290).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: baseTimestamp.littleEndian) { Array($0) })
        data.append(FITSport.running.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: (elapsedSeconds * 1_000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (timerSeconds * 1_000).littleEndian) { Array($0) })
        let firstLapIndex: UInt16 = 0
        data.append(contentsOf: withUnsafeBytes(of: firstLapIndex.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numberOfLaps.littleEndian) { Array($0) })
    }

    private static func writeLapDefinitionMessage(to data: inout Data) {
        data.append(0x42) // definition, local type 2
        data.append(0x00) // reserved
        data.append(0x00) // little-endian
        data.append(contentsOf: [0x13, 0x00]) // global message 19 (lap)
        data.append(8)
        writeFieldDef(field: 254, size: 2, type: 132, to: &data) // message_index
        writeFieldDef(field: 253, size: 4, type: 134, to: &data) // timestamp
        writeFieldDef(field: 2, size: 4, type: 134, to: &data)   // start_time
        writeFieldDef(field: 7, size: 4, type: 134, to: &data)   // total_elapsed_time
        writeFieldDef(field: 8, size: 4, type: 134, to: &data)   // total_timer_time
        writeFieldDef(field: 9, size: 4, type: 134, to: &data)   // total_distance
        writeFieldDef(field: 11, size: 2, type: 132, to: &data)  // total_calories
        writeFieldDef(field: 24, size: 1, type: 0, to: &data)    // lap_trigger (enum)
    }

    private static func writeLapMessage(
        messageIndex: UInt16,
        startOffset: UInt32,
        endOffset: UInt32,
        elapsedSeconds: UInt32,
        timerSeconds: UInt32,
        distanceMeters: UInt32,
        calories: UInt16,
        trigger: UInt8,
        to data: inout Data
    ) {
        let baseTimestamp: UInt32 = 1_000_000_000
        data.append(0x02) // data message, local type 2
        data.append(contentsOf: withUnsafeBytes(of: messageIndex.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (baseTimestamp + endOffset).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (baseTimestamp + startOffset).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (elapsedSeconds * 1_000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (timerSeconds * 1_000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: (distanceMeters * 100).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: calories.littleEndian) { Array($0) })
        data.append(trigger)
    }

    private static func writeMalformedLapMessage(to data: inout Data) {
        data.append(0x02) // data message, local type 2
        let messageIndex: UInt16 = 0
        let invalidTimestamp = UInt32.max
        let zero: UInt32 = 0
        let zeroCalories: UInt16 = 0
        data.append(contentsOf: withUnsafeBytes(of: messageIndex.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: invalidTimestamp.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: invalidTimestamp.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: zero.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: zero.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: zero.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: zeroCalories.littleEndian) { Array($0) })
        data.append(0) // manual trigger
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
