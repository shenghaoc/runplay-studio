import Foundation

/// Errors that can occur during FIT parsing.
public enum FITError: Error, LocalizedError, Sendable {
    case emptyFile
    case invalidHeader
    case unsupportedProtocol(UInt8)
    case invalidDataType
    case unexpectedEndOfFile
    case missingDefinition(UInt8)
    case noRecordMessages
    case noGPSCoordinates
    case invalidCoordinates
    case corruptedData(String)
    case headerCRCMismatch
    case fileCRCMismatch
    case invalidArchitecture(UInt8)
    case compressedTimestampWithoutBaseline
    case invalidCompressedDefinition
    case unsupportedCompressedTimestamp

    public var errorDescription: String? {
        switch self {
        case .emptyFile: return "FIT file is empty"
        case .invalidHeader: return "Invalid FIT file header"
        case .unsupportedProtocol(let v): return "Unsupported FIT protocol version: \(v)"
        case .invalidDataType: return "Invalid FIT data type (expected 'FIT ')"
        case .unexpectedEndOfFile: return "Unexpected end of FIT file"
        case .missingDefinition(let t): return "Missing definition for message type \(t)"
        case .noRecordMessages: return "No record messages found in FIT file"
        case .noGPSCoordinates: return "No GPS coordinates found in FIT file"
        case .invalidCoordinates: return "Invalid coordinates in FIT file"
        case .corruptedData(let d): return "Corrupted FIT data: \(d)"
        case .headerCRCMismatch: return "FIT header CRC mismatch — file may be corrupted"
        case .fileCRCMismatch: return "FIT file CRC mismatch — file may be corrupted"
        case .invalidArchitecture(let v): return "Invalid FIT architecture byte: \(v)"
        case .compressedTimestampWithoutBaseline: return "Compressed timestamp received before any baseline timestamp"
        case .invalidCompressedDefinition: return "Compressed timestamp header references invalid definition"
        case .unsupportedCompressedTimestamp: return "Compressed timestamp headers are not supported for this definition"
        }
    }
}

/// FIT field definition from definition message.
public struct FITFieldDefinition: Sendable {
    let fieldNumber: UInt8
    let size: UInt8
    let baseType: FITBaseType

    public init(fieldNumber: UInt8, size: UInt8, baseType: FITBaseType) {
        self.fieldNumber = fieldNumber
        self.size = size
        self.baseType = baseType
    }
}

/// FIT definition message for a local message type.
public struct FITDefinitionMessage: Sendable {
    let architecture: UInt8      // 0=little-endian, 1=big-endian
    let globalMessageNumber: UInt16
    let fields: [FITFieldDefinition]
    let developerFields: [FITDeveloperFieldDefinition]

    /// Total data size in bytes for a data message using this definition.
    var totalDataSize: Int {
        fields.reduce(0) { $0 + Int($1.size) }
            + developerFields.reduce(0) { $0 + Int($1.size) }
    }
}

/// FIT developer field definition from a definition message.
struct FITDeveloperFieldDefinition: Sendable {
    let fieldNumber: UInt8
    let size: UInt8
    let developerDataIndex: UInt8
}

/// Parser for FIT binary files.
///
/// Decodes the FIT binary format into ordered standard messages.
/// Supports compressed timestamp headers, all required message types,
/// and proper base-type decoding.
public struct FITParser {

    public init() {}

    // FIT constants
    static let fitDataType: [UInt8] = [0x46, 0x49, 0x54, 0x20] // "FIT "
    static let fitEpoch: TimeInterval = 631065600 // 1989-12-31 00:00:00 UTC

    // Compressed timestamp constants
    static let compressedHeaderMask: UInt8 = 0x80
    static let compressedLocalTypeMask: UInt8 = 0x60
    static let compressedLocalTypeShift: UInt8 = 5
    static let compressedTimeOffsetMask: UInt8 = 0x1F
    static let compressedTimeOffsetBits: Int = 5

    // Sentinel values (legacy, kept for backward compatibility)
    static let invalidCoordinate: Int32 = 0x7FFFFFFF
    static let invalidUint16: UInt16 = 0xFFFF
    static let invalidUint32: UInt32 = 0xFFFFFFFF
    static let invalidUint8: UInt8 = 0xFF

    // Resource limits
    static let maxFileSize: Int = 100 * 1024 * 1024 // 100 MB
    static let maxDefinitions: Int = 256
    static let maxFieldCount: Int = 256
    static let maxFieldSize: Int = 255
    static let maxRecordCount: Int = 1_000_000

    /// Checkpoint interval for cancellation checks (every N records).
    static let cancellationCheckInterval: Int = 1000

    // MARK: - Public API

    /// Parse FIT binary data and return a decoded file with all message types.
    public static func parse(
        data: Data,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> FITDecodedFile {
        guard !data.isEmpty else {
            throw FITError.emptyFile
        }

        guard data.count <= maxFileSize else {
            throw FITError.corruptedData("FIT file exceeds maximum size of \(maxFileSize / (1024 * 1024)) MB")
        }

        var offset = 0

        // Parse header
        let dataEndOffset = try parseHeader(data: data, offset: &offset)

        // Parse data records
        var definitions: [UInt8: FITDefinitionMessage] = [:]
        var decodedFile = FITDecodedFile()
        var messageIndex = 0
        var lastTimestamp: UInt32 = 0
        var hasBaselineTimestamp = false
        var recordCount = 0

        while offset < dataEndOffset {
            // Cooperative cancellation check
            if messageIndex % cancellationCheckInterval == 0 && isCancelled() {
                throw CancellationError()
            }

            guard offset < dataEndOffset else { break }
            let recordHeader = data[offset]
            offset += 1

            // Check for compressed timestamp header (bit 7 set)
            if recordHeader & compressedHeaderMask != 0 {
                let localType = (recordHeader & compressedLocalTypeMask) >> compressedLocalTypeShift
                let timeOffset = UInt32(recordHeader & compressedTimeOffsetMask)

                guard hasBaselineTimestamp else {
                    throw FITError.compressedTimestampWithoutBaseline
                }

                guard let def = definitions[localType] else {
                    throw FITError.invalidCompressedDefinition
                }

                // Reconstruct timestamp with wrap handling
                // FIT SDK: offsetDelta is masked to 5 bits; always added to lastTimestamp
                let offsetDelta = (timeOffset &- (lastTimestamp & UInt32(compressedTimeOffsetMask)))
                    & UInt32(compressedTimeOffsetMask)
                let timestamp = lastTimestamp &+ offsetDelta
                lastTimestamp = timestamp

                // Parse the data message (compressed headers don't include the timestamp field)
                let timestampFieldSize = def.fields
                    .first { $0.fieldNumber == 253 }
                    .map { Int($0.size) } ?? 0
                let dataSize = def.totalDataSize - timestampFieldSize
                guard offset + dataSize <= dataEndOffset else {
                    throw FITError.unexpectedEndOfFile
                }

                let isLittleEndian = def.architecture == 0
                var reader = FITBinaryReader(
                    data: data,
                    offset: offset,
                    endOffset: offset + dataSize,
                    littleEndian: isLittleEndian
                )

                // Read field values (timestamp is NOT in the payload for compressed records)
                var fieldValues: [UInt8: FITFieldValue] = [:]
                for field in def.fields {
                    if field.fieldNumber == 253 {
                        // Timestamp field is encoded in the compressed header, not in payload
                        continue
                    }
                    // Use readBaseTypeArray to consume all field.size bytes
                    let values = try reader.readBaseTypeArray(
                        baseType: field.baseType,
                        fieldSize: Int(field.size)
                    )
                    // Store the first value; multi-element fields are handled by readBaseTypeArray
                    if let firstValue = values.first {
                        fieldValues[field.fieldNumber] = firstValue
                    }
                }

                // Skip developer fields
                for field in def.developerFields {
                    try reader.skip(Int(field.size))
                }

                offset = reader.offset

                messageIndex += 1

                switch def.globalMessageNumber {
                case FITGlobalMessage.record.rawValue:
                    var record = FITRecordMessage()
                    record.timestamp = timestamp
                    record.positionLat = fieldValues[FITRecordField.positionLat.rawValue]?.int32Value
                    record.positionLong = fieldValues[FITRecordField.positionLong.rawValue]?.int32Value
                    record.altitude = fieldValues[FITRecordField.altitude.rawValue]?.uint16Value
                    record.enhancedAltitude = fieldValues[FITRecordField.enhancedAltitude.rawValue]?.uint32Value
                    record.distance = fieldValues[FITRecordField.distance.rawValue]?.uint32Value
                    record.speed = fieldValues[FITRecordField.speed.rawValue]?.uint16Value
                    record.enhancedSpeed = fieldValues[FITRecordField.enhancedSpeed.rawValue]?.uint32Value
                    record.heartRate = fieldValues[FITRecordField.heartRate.rawValue]?.uint8Value
                    record.cadence = fieldValues[FITRecordField.cadence.rawValue]?.uint8Value
                    record.temperature = fieldValues[FITRecordField.temperature.rawValue]?.int8Value
                    decodedFile.records.append(record)
                    recordCount += 1
                    if recordCount > maxRecordCount {
                        throw FITError.corruptedData("Record count exceeds maximum of \(maxRecordCount)")
                    }

                case FITGlobalMessage.event.rawValue:
                    var event = FITEventMessage()
                    event.timestamp = timestamp
                    event.event = fieldValues[FITEventField.event.rawValue]?.uint8Value
                    event.eventType = fieldValues[FITEventField.eventType.rawValue]?.uint8Value
                    event.eventGroup = fieldValues[FITEventField.eventGroup.rawValue]?.uint8Value
                    decodedFile.events.append(event)

                case FITGlobalMessage.fileID.rawValue:
                    var msg = FITFileIDMessage()
                    msg.type = fieldValues[FITFileIDField.type.rawValue]?.uint8Value
                    msg.manufacturer = fieldValues[FITFileIDField.manufacturer.rawValue]?.uint16Value
                    msg.product = fieldValues[FITFileIDField.product.rawValue]?.uint16Value
                    msg.serialNumber = fieldValues[FITFileIDField.serialNumber.rawValue]?.uint32Value
                    msg.timeCreated = fieldValues[FITFileIDField.timeCreated.rawValue]?.uint32Value
                    msg.number = fieldValues[FITFileIDField.number.rawValue]?.uint16Value
                    decodedFile.fileID = msg

                case FITGlobalMessage.lap.rawValue:
                    var lap = FITLapMessage()
                    lap.timestamp = fieldValues[FITLapField.timestamp.rawValue]?.uint32Value
                    lap.startTime = fieldValues[FITLapField.startTime.rawValue]?.uint32Value
                    lap.startPositionLat = fieldValues[FITLapField.startPositionLat.rawValue]?.int32Value
                    lap.startPositionLong = fieldValues[FITLapField.startPositionLong.rawValue]?.int32Value
                    lap.endPositionLat = fieldValues[FITLapField.endPositionLat.rawValue]?.int32Value
                    lap.endPositionLong = fieldValues[FITLapField.endPositionLong.rawValue]?.int32Value
                    lap.totalElapsedTime = fieldValues[FITLapField.totalElapsedTime.rawValue]?.uint32Value
                    lap.totalTimerTime = fieldValues[FITLapField.totalTimerTime.rawValue]?.uint32Value
                    lap.totalDistance = fieldValues[FITLapField.totalDistance.rawValue]?.uint32Value
                    lap.totalAscent = fieldValues[FITLapField.totalAscent.rawValue]?.uint16Value
                    lap.totalDescent = fieldValues[FITLapField.totalDescent.rawValue]?.uint16Value
                    lap.averageSpeed = fieldValues[FITLapField.averageSpeed.rawValue]?.uint16Value
                    lap.maximumSpeed = fieldValues[FITLapField.maximumSpeed.rawValue]?.uint16Value
                    lap.averageHeartRate = fieldValues[FITLapField.averageHeartRate.rawValue]?.uint8Value
                    lap.maximumHeartRate = fieldValues[FITLapField.maximumHeartRate.rawValue]?.uint8Value
                    lap.averageCadence = fieldValues[FITLapField.averageCadence.rawValue]?.uint8Value
                    lap.event = fieldValues[FITLapField.event.rawValue]?.uint8Value
                    lap.eventType = fieldValues[FITLapField.eventType.rawValue]?.uint8Value
                    lap.eventGroup = fieldValues[FITLapField.eventGroup.rawValue]?.uint8Value
                    lap.lapTrigger = fieldValues[FITLapField.lapTrigger.rawValue]?.uint8Value
                    lap.sport = fieldValues[FITLapField.sport.rawValue]?.uint8Value
                    decodedFile.laps.append(lap)

                case FITGlobalMessage.session.rawValue:
                    var session = FITSessionMessage()
                    session.timestamp = fieldValues[FITSessionField.timestamp.rawValue]?.uint32Value
                    session.startTime = fieldValues[FITSessionField.startTime.rawValue]?.uint32Value
                    session.startPositionLat = fieldValues[FITSessionField.startPositionLat.rawValue]?.int32Value
                    session.startPositionLong = fieldValues[FITSessionField.startPositionLong.rawValue]?.int32Value
                    session.sport = fieldValues[FITSessionField.sport.rawValue]?.uint8Value
                    session.subSport = fieldValues[FITSessionField.subSport.rawValue]?.uint8Value
                    session.totalElapsedTime = fieldValues[FITSessionField.totalElapsedTime.rawValue]?.uint32Value
                    session.totalTimerTime = fieldValues[FITSessionField.totalTimerTime.rawValue]?.uint32Value
                    session.totalDistance = fieldValues[FITSessionField.totalDistance.rawValue]?.uint32Value
                    session.totalAscent = fieldValues[FITSessionField.totalAscent.rawValue]?.uint16Value
                    session.totalDescent = fieldValues[FITSessionField.totalDescent.rawValue]?.uint16Value
                    session.averageSpeed = fieldValues[FITSessionField.averageSpeed.rawValue]?.uint16Value
                    session.maximumSpeed = fieldValues[FITSessionField.maximumSpeed.rawValue]?.uint16Value
                    session.averageHeartRate = fieldValues[FITSessionField.averageHeartRate.rawValue]?.uint8Value
                    session.maximumHeartRate = fieldValues[FITSessionField.maximumHeartRate.rawValue]?.uint8Value
                    session.averageCadence = fieldValues[FITSessionField.averageCadence.rawValue]?.uint8Value
                    session.event = fieldValues[FITSessionField.event.rawValue]?.uint8Value
                    session.eventType = fieldValues[FITSessionField.eventType.rawValue]?.uint8Value
                    session.eventGroup = fieldValues[23]?.uint8Value  // eventGroup — no enum case (conflicts with totalDescent)
                    session.trigger = fieldValues[FITSessionField.trigger.rawValue]?.uint8Value
                    session.necLong = fieldValues[FITSessionField.necLong.rawValue]?.int32Value
                    session.necLat = fieldValues[FITSessionField.necLat.rawValue]?.int32Value
                    session.swcLong = fieldValues[FITSessionField.swcLong.rawValue]?.int32Value
                    session.swcLat = fieldValues[FITSessionField.swcLat.rawValue]?.int32Value
                    decodedFile.sessions.append(session)

                case FITGlobalMessage.activity.rawValue:
                    // Activity messages parsed but not stored separately in this version
                    break

                case FITGlobalMessage.deviceInfo.rawValue:
                    var deviceInfo = FITDeviceInfoMessage()
                    deviceInfo.timestamp = fieldValues[FITDeviceInfoField.timestamp.rawValue]?.uint32Value
                    deviceInfo.serialNumber = fieldValues[FITDeviceInfoField.serialNumber.rawValue]?.uint32Value
                    deviceInfo.manufacturer = fieldValues[FITDeviceInfoField.manufacturer.rawValue]?.uint16Value
                    deviceInfo.product = fieldValues[FITDeviceInfoField.product.rawValue]?.uint16Value
                    deviceInfo.softwareVersion = fieldValues[FITDeviceInfoField.softwareVersion.rawValue]?.uint16Value
                    deviceInfo.hardwareVersion = fieldValues[FITDeviceInfoField.hardwareVersion.rawValue]?.uint8Value
                    deviceInfo.deviceIndex = fieldValues[FITDeviceInfoField.deviceIndex.rawValue]?.uint8Value
                    deviceInfo.deviceType = fieldValues[FITDeviceInfoField.deviceType.rawValue]?.uint8Value
                    deviceInfo.productName = fieldValues[FITDeviceInfoField.productName.rawValue]?.stringValue
                    decodedFile.deviceInfo.append(deviceInfo)

                default:
                    // Unknown messages are skipped silently
                    break
                }
            } else {
                // Normal or definition message
                let isDefinition = (recordHeader & 0x40) != 0
                let hasDeveloperData = isDefinition && (recordHeader & 0x20) != 0
                let localType = recordHeader & 0x0F

                if isDefinition {
                    let def = try parseDefinition(
                        data: data,
                        offset: &offset,
                        dataEndOffset: dataEndOffset,
                        localType: localType,
                        hasDeveloperData: hasDeveloperData
                    )
                    definitions[localType] = def
                } else {
                    guard let def = definitions[localType] else {
                        throw FITError.missingDefinition(localType)
                    }

                    try parseDataMessage(
                        data: data,
                        offset: &offset,
                        dataEndOffset: dataEndOffset,
                        definition: def,
                        localType: localType,
                        lastTimestamp: &lastTimestamp,
                        hasBaselineTimestamp: &hasBaselineTimestamp,
                        messageIndex: &messageIndex,
                        decodedFile: &decodedFile,
                        recordCount: &recordCount
                    )
                }
            }
        }

        return decodedFile
    }

    // MARK: - Header Parsing

    /// Parse FIT file header. Returns the exclusive end offset for data records.
    static func parseHeader(data: Data, offset: inout Int) throws -> Int {
        guard data.count >= 12 else {
            throw FITError.invalidHeader
        }

        let headerLength = Int(data[0])
        guard headerLength == 14 || headerLength == 12 else {
            throw FITError.invalidHeader
        }

        // Check protocol version
        let protocolVersion = data[1]
        guard protocolVersion <= 32 else {
            throw FITError.unsupportedProtocol(protocolVersion)
        }

        // Check data type
        let dataType = Array(data[8..<12])
        guard dataType == fitDataType else {
            throw FITError.invalidDataType
        }

        // Validate header CRC (only present in 14-byte headers).
        // A header CRC of 0x0000 means the CRC was not computed; skip validation.
        if headerLength == 14 {
            guard data.count >= 14 else {
                throw FITError.invalidHeader
            }
            let expectedCRC = readUInt16(data: data[12..<14], littleEndian: true)
            if expectedCRC != 0 {
                let computedCRC = crc16(over: data[0..<12])
                guard expectedCRC == computedCRC else {
                    throw FITError.headerCRCMismatch
                }
            }
        }

        let dataSize = Int(readUInt32(data: data[4..<8], littleEndian: true))
        let dataStart = headerLength
        let dataEnd = dataStart + dataSize
        guard data.count >= dataEnd + 2 else {
            throw FITError.unexpectedEndOfFile
        }
        guard data.count == dataEnd + 2 else {
            throw FITError.corruptedData("FIT file contains trailing bytes after its CRC")
        }

        // Validate entire-file CRC (covers header + all data records).
        let expectedFileCRC = readUInt16(data: data[dataEnd..<(dataEnd + 2)], littleEndian: true)
        let computedFileCRC = crc16(over: data[0..<dataEnd])
        guard expectedFileCRC == computedFileCRC else {
            throw FITError.fileCRCMismatch
        }

        offset = headerLength
        return dataEnd
    }

    // MARK: - Definition Message Parsing

    /// Parse a definition message.
    static func parseDefinition(
        data: Data,
        offset: inout Int,
        dataEndOffset: Int,
        localType: UInt8,
        hasDeveloperData: Bool
    ) throws -> FITDefinitionMessage {
        guard offset + 5 <= dataEndOffset else {
            throw FITError.unexpectedEndOfFile
        }

        let _ = data[offset] // reserved byte
        offset += 1

        let architecture = data[offset]
        guard architecture == 0 || architecture == 1 else {
            throw FITError.invalidArchitecture(architecture)
        }
        offset += 1

        let isLittleEndian = architecture == 0

        // Global message number (2 bytes)
        let globalMessageNumber: UInt16
        if isLittleEndian {
            globalMessageNumber = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            globalMessageNumber = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
        offset += 2

        let fieldCount = Int(data[offset])
        guard fieldCount <= maxFieldCount else {
            throw FITError.corruptedData("Field count \(fieldCount) exceeds maximum \(maxFieldCount)")
        }
        offset += 1

        var fields: [FITFieldDefinition] = []
        fields.reserveCapacity(fieldCount)
        for _ in 0..<fieldCount {
            guard offset + 3 <= dataEndOffset else {
                throw FITError.unexpectedEndOfFile
            }

            let fieldNum = data[offset]
            let fieldSize = data[offset + 1]
            guard Int(fieldSize) <= maxFieldSize else {
                throw FITError.corruptedData("Field size \(fieldSize) exceeds maximum \(maxFieldSize)")
            }
            let fieldType = data[offset + 2]
            offset += 3

            // Use full type byte to look up base type (matches FIT SDK convention)
            guard let baseType = FITBaseType(rawValue: fieldType) else {
                // Unknown base type - treat as byte array
                fields.append(FITFieldDefinition(
                    fieldNumber: fieldNum,
                    size: fieldSize,
                    baseType: .byte
                ))
                continue
            }

            fields.append(FITFieldDefinition(
                fieldNumber: fieldNum,
                size: fieldSize,
                baseType: baseType
            ))
        }

        let developerFields: [FITDeveloperFieldDefinition]
        if hasDeveloperData {
            guard offset + 1 <= dataEndOffset else {
                throw FITError.unexpectedEndOfFile
            }

            let developerFieldCount = Int(data[offset])
            offset += 1

            var parsedDeveloperFields: [FITDeveloperFieldDefinition] = []
            parsedDeveloperFields.reserveCapacity(developerFieldCount)
            for _ in 0..<developerFieldCount {
                guard offset + 3 <= dataEndOffset else {
                    throw FITError.unexpectedEndOfFile
                }

                parsedDeveloperFields.append(FITDeveloperFieldDefinition(
                    fieldNumber: data[offset],
                    size: data[offset + 1],
                    developerDataIndex: data[offset + 2]
                ))
                offset += 3
            }
            developerFields = parsedDeveloperFields
        } else {
            developerFields = []
        }

        return FITDefinitionMessage(
            architecture: architecture,
            globalMessageNumber: globalMessageNumber,
            fields: fields,
            developerFields: developerFields
        )
    }

    // MARK: - Data Message Parsing

    /// Parse a normal (non-compressed) data message.
    private static func parseDataMessage(
        data: Data,
        offset: inout Int,
        dataEndOffset: Int,
        definition: FITDefinitionMessage,
        localType: UInt8,
        lastTimestamp: inout UInt32,
        hasBaselineTimestamp: inout Bool,
        messageIndex: inout Int,
        decodedFile: inout FITDecodedFile,
        recordCount: inout Int
    ) throws {
        let dataSize = definition.totalDataSize
        guard offset + dataSize <= dataEndOffset else {
            throw FITError.unexpectedEndOfFile
        }

        let isLittleEndian = definition.architecture == 0
        var reader = FITBinaryReader(
            data: data,
            offset: offset,
            endOffset: offset + dataSize,
            littleEndian: isLittleEndian
        )

        // Read field values
        var fieldValues: [UInt8: FITFieldValue] = [:]
        for field in definition.fields {
            // Use readBaseTypeArray to consume all field.size bytes
            let values = try reader.readBaseTypeArray(
                baseType: field.baseType,
                fieldSize: Int(field.size)
            )
            // Store the first value; multi-element fields are handled by readBaseTypeArray
            if let firstValue = values.first {
                fieldValues[field.fieldNumber] = firstValue
            }
        }

        // Skip developer fields
        for field in definition.developerFields {
            try reader.skip(Int(field.size))
        }

        offset = reader.offset

        // Update timestamp if present
        if let timestampField = fieldValues[253],
           let timestamp = timestampField.uint32Value {
            lastTimestamp = timestamp
            hasBaselineTimestamp = true
        }

        // Build typed message based on global message number
        messageIndex += 1

        switch definition.globalMessageNumber {
        case FITGlobalMessage.fileID.rawValue:
            var msg = FITFileIDMessage()
            msg.type = fieldValues[FITFileIDField.type.rawValue]?.uint8Value
            msg.manufacturer = fieldValues[FITFileIDField.manufacturer.rawValue]?.uint16Value
            msg.product = fieldValues[FITFileIDField.product.rawValue]?.uint16Value
            msg.serialNumber = fieldValues[FITFileIDField.serialNumber.rawValue]?.uint32Value
            msg.timeCreated = fieldValues[FITFileIDField.timeCreated.rawValue]?.uint32Value
            msg.number = fieldValues[FITFileIDField.number.rawValue]?.uint16Value
            decodedFile.fileID = msg

        case FITGlobalMessage.record.rawValue:
            var record = FITRecordMessage()
            record.timestamp = fieldValues[FITRecordField.timestamp.rawValue]?.uint32Value
            record.positionLat = fieldValues[FITRecordField.positionLat.rawValue]?.int32Value
            record.positionLong = fieldValues[FITRecordField.positionLong.rawValue]?.int32Value
            record.altitude = fieldValues[FITRecordField.altitude.rawValue]?.uint16Value
            record.enhancedAltitude = fieldValues[FITRecordField.enhancedAltitude.rawValue]?.uint32Value
            record.distance = fieldValues[FITRecordField.distance.rawValue]?.uint32Value
            record.speed = fieldValues[FITRecordField.speed.rawValue]?.uint16Value
            record.enhancedSpeed = fieldValues[FITRecordField.enhancedSpeed.rawValue]?.uint32Value
            record.heartRate = fieldValues[FITRecordField.heartRate.rawValue]?.uint8Value
            record.cadence = fieldValues[FITRecordField.cadence.rawValue]?.uint8Value
            record.temperature = fieldValues[FITRecordField.temperature.rawValue]?.int8Value
            decodedFile.records.append(record)
            recordCount += 1
            if recordCount > maxRecordCount {
                throw FITError.corruptedData("Record count exceeds maximum of \(maxRecordCount)")
            }

        case FITGlobalMessage.event.rawValue:
            var event = FITEventMessage()
            event.timestamp = fieldValues[FITEventField.timestamp.rawValue]?.uint32Value
            event.event = fieldValues[FITEventField.event.rawValue]?.uint8Value
            event.eventType = fieldValues[FITEventField.eventType.rawValue]?.uint8Value
            event.eventGroup = fieldValues[FITEventField.eventGroup.rawValue]?.uint8Value
            decodedFile.events.append(event)

        case FITGlobalMessage.lap.rawValue:
            var lap = FITLapMessage()
            lap.timestamp = fieldValues[FITLapField.timestamp.rawValue]?.uint32Value
            lap.startTime = fieldValues[FITLapField.startTime.rawValue]?.uint32Value
            lap.startPositionLat = fieldValues[FITLapField.startPositionLat.rawValue]?.int32Value
            lap.startPositionLong = fieldValues[FITLapField.startPositionLong.rawValue]?.int32Value
            lap.endPositionLat = fieldValues[FITLapField.endPositionLat.rawValue]?.int32Value
            lap.endPositionLong = fieldValues[FITLapField.endPositionLong.rawValue]?.int32Value
            lap.totalElapsedTime = fieldValues[FITLapField.totalElapsedTime.rawValue]?.uint32Value
            lap.totalTimerTime = fieldValues[FITLapField.totalTimerTime.rawValue]?.uint32Value
            lap.totalDistance = fieldValues[FITLapField.totalDistance.rawValue]?.uint32Value
            lap.totalAscent = fieldValues[FITLapField.totalAscent.rawValue]?.uint16Value
            lap.totalDescent = fieldValues[FITLapField.totalDescent.rawValue]?.uint16Value
            lap.averageSpeed = fieldValues[FITLapField.averageSpeed.rawValue]?.uint16Value
            lap.maximumSpeed = fieldValues[FITLapField.maximumSpeed.rawValue]?.uint16Value
            lap.averageHeartRate = fieldValues[FITLapField.averageHeartRate.rawValue]?.uint8Value
            lap.maximumHeartRate = fieldValues[FITLapField.maximumHeartRate.rawValue]?.uint8Value
            lap.averageCadence = fieldValues[FITLapField.averageCadence.rawValue]?.uint8Value
            lap.event = fieldValues[FITLapField.event.rawValue]?.uint8Value
            lap.eventType = fieldValues[FITLapField.eventType.rawValue]?.uint8Value
            lap.eventGroup = fieldValues[FITLapField.eventGroup.rawValue]?.uint8Value
            lap.lapTrigger = fieldValues[FITLapField.lapTrigger.rawValue]?.uint8Value
            lap.sport = fieldValues[FITLapField.sport.rawValue]?.uint8Value
            decodedFile.laps.append(lap)

        case FITGlobalMessage.session.rawValue:
            var session = FITSessionMessage()
            session.timestamp = fieldValues[FITSessionField.timestamp.rawValue]?.uint32Value
            session.startTime = fieldValues[FITSessionField.startTime.rawValue]?.uint32Value
            session.startPositionLat = fieldValues[FITSessionField.startPositionLat.rawValue]?.int32Value
            session.startPositionLong = fieldValues[FITSessionField.startPositionLong.rawValue]?.int32Value
            session.sport = fieldValues[FITSessionField.sport.rawValue]?.uint8Value
            session.subSport = fieldValues[FITSessionField.subSport.rawValue]?.uint8Value
            session.totalElapsedTime = fieldValues[FITSessionField.totalElapsedTime.rawValue]?.uint32Value
            session.totalTimerTime = fieldValues[FITSessionField.totalTimerTime.rawValue]?.uint32Value
            session.totalDistance = fieldValues[FITSessionField.totalDistance.rawValue]?.uint32Value
            session.totalAscent = fieldValues[FITSessionField.totalAscent.rawValue]?.uint16Value
            session.totalDescent = fieldValues[FITSessionField.totalDescent.rawValue]?.uint16Value
            session.averageSpeed = fieldValues[FITSessionField.averageSpeed.rawValue]?.uint16Value
            session.maximumSpeed = fieldValues[FITSessionField.maximumSpeed.rawValue]?.uint16Value
            session.averageHeartRate = fieldValues[FITSessionField.averageHeartRate.rawValue]?.uint8Value
            session.maximumHeartRate = fieldValues[FITSessionField.maximumHeartRate.rawValue]?.uint8Value
            session.averageCadence = fieldValues[FITSessionField.averageCadence.rawValue]?.uint8Value
            session.event = fieldValues[FITSessionField.event.rawValue]?.uint8Value
            session.eventType = fieldValues[FITSessionField.eventType.rawValue]?.uint8Value
            session.eventGroup = fieldValues[23]?.uint8Value  // eventGroup — no enum case (conflicts with totalDescent)
            session.trigger = fieldValues[FITSessionField.trigger.rawValue]?.uint8Value
            session.necLong = fieldValues[FITSessionField.necLong.rawValue]?.int32Value
            session.necLat = fieldValues[FITSessionField.necLat.rawValue]?.int32Value
            session.swcLong = fieldValues[FITSessionField.swcLong.rawValue]?.int32Value
            session.swcLat = fieldValues[FITSessionField.swcLat.rawValue]?.int32Value
            decodedFile.sessions.append(session)

        case FITGlobalMessage.activity.rawValue:
            // Activity messages parsed but not stored separately in this version
            break

        case FITGlobalMessage.deviceInfo.rawValue:
            var deviceInfo = FITDeviceInfoMessage()
            deviceInfo.timestamp = fieldValues[FITDeviceInfoField.timestamp.rawValue]?.uint32Value
            deviceInfo.serialNumber = fieldValues[FITDeviceInfoField.serialNumber.rawValue]?.uint32Value
            deviceInfo.manufacturer = fieldValues[FITDeviceInfoField.manufacturer.rawValue]?.uint16Value
            deviceInfo.product = fieldValues[FITDeviceInfoField.product.rawValue]?.uint16Value
            deviceInfo.softwareVersion = fieldValues[FITDeviceInfoField.softwareVersion.rawValue]?.uint16Value
            deviceInfo.hardwareVersion = fieldValues[FITDeviceInfoField.hardwareVersion.rawValue]?.uint8Value
            deviceInfo.deviceIndex = fieldValues[FITDeviceInfoField.deviceIndex.rawValue]?.uint8Value
            deviceInfo.deviceType = fieldValues[FITDeviceInfoField.deviceType.rawValue]?.uint8Value
            deviceInfo.productName = fieldValues[FITDeviceInfoField.productName.rawValue]?.stringValue
            decodedFile.deviceInfo.append(deviceInfo)

        default:
            // Unknown messages are skipped silently
            break
        }
    }

    // MARK: - Legacy API (backward compatibility)

    /// Parse FIT binary data and return only record messages.
    /// This is the legacy API maintained for backward compatibility.
    public static func parseRecords(data: Data) throws -> [FITRecordMessage] {
        let decoded = try parse(data: data)
        return decoded.records
    }

    // MARK: - CRC-16 (FIT SDK)

    /// CRC-16 lookup table for FIT SDK polynomial 0x8005 (reflected: 0xA001).
    private static let crc16Table: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt16(i)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001  // reflected polynomial 0x8005
                } else {
                    crc >>= 1
                }
            }
            table[i] = crc
        }
        return table
    }()

    /// Compute CRC-16 over a byte sequence using the FIT SDK algorithm.
    public static func crc16<S: Sequence>(over bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            let index = Int(crc ^ UInt16(byte)) & 0xFF
            crc = (crc >> 8) ^ crc16Table[index]
        }
        return crc
    }

    // MARK: - Binary Reading Helpers (legacy)

    static func readUInt16(data: Data.SubSequence, littleEndian: Bool) -> UInt16 {
        let bytes = Array(data.prefix(2))
        if littleEndian {
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        } else {
            return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        }
    }

    static func readInt32(data: Data.SubSequence, littleEndian: Bool) -> Int32 {
        Int32(bitPattern: readUInt32(data: data, littleEndian: littleEndian))
    }

    static func readUInt32(data: Data.SubSequence, littleEndian: Bool) -> UInt32 {
        let bytes = Array(data.prefix(4))
        if littleEndian {
            return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        } else {
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }
    }
}

// MARK: - FIT Scaling and Conversion

extension FITParser {

    /// Convert semicircle coordinates to degrees.
    public static func semicirclesToDegrees(_ semicircles: Int32) -> Double {
        Double(semicircles) * (180.0 / pow(2.0, 31))
    }

    /// Convert FIT timestamp to Date.
    public static func timestampToDate(_ timestamp: UInt32) -> Date {
        Date(timeIntervalSince1970: fitEpoch + Double(timestamp))
    }

    /// Convert scaled altitude to meters.
    public static func scaledAltitudeToMeters(_ scaled: UInt16) -> Double {
        (Double(scaled) / 5.0) - 500.0
    }

    /// Convert enhanced altitude (UInt32) to meters.
    /// Enhanced altitude uses scale 5, offset 500, but stored as UInt32.
    public static func enhancedAltitudeToMeters(_ scaled: UInt32) -> Double {
        (Double(scaled) / 5.0) - 500.0
    }

    /// Convert scaled distance to meters.
    public static func scaledDistanceToMeters(_ scaled: UInt32) -> Double {
        Double(scaled) / 100.0
    }

    /// Convert scaled speed to m/s.
    public static func scaledSpeedToMPS(_ scaled: UInt16) -> Double {
        Double(scaled) / 1000.0
    }

    /// Convert enhanced speed (UInt32) to m/s.
    /// Enhanced speed uses scale 1000, same as legacy.
    public static func enhancedSpeedToMPS(_ scaled: UInt32) -> Double {
        Double(scaled) / 1000.0
    }
}
