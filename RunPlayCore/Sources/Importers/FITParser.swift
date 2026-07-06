import Foundation

/// Errors that can occur during FIT parsing.
public enum FITError: Error, LocalizedError {
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
        }
    }
}

/// Raw FIT record message with field values.
public struct FITRecordMessage {

    public var timestamp: UInt32?
    public var positionLat: Int32?      // semicircles
    public var positionLong: Int32?     // semicircles
    public var altitude: UInt16?        // scaled
    public var enhancedAltitude: UInt16?
    public var distance: UInt32?        // scaled
    public var speed: UInt16?           // scaled
    public var enhancedSpeed: UInt16?
    public var heartRate: UInt8?
    public var cadence: UInt8?
}

/// FIT field definition from definition message.
public struct FITFieldDefinition {

    public let fieldNumber: UInt8
    public let size: UInt8
    public let type: UInt8
}

/// FIT definition message for a local message type.
public struct FITDefinitionMessage {

    public let architecture: UInt8      // 0=little-endian, 1=big-endian
    public let globalMessageNumber: UInt16
    public let fields: [FITFieldDefinition]
}

/// Parser for FIT binary files.
///
/// Parses the FIT binary format to extract record messages
/// containing GPS, altitude, heart rate, and cadence data.
public struct FITParser {

    public init() {}

    // FIT constants
    static let fitDataType: [UInt8] = [0x46, 0x49, 0x54, 0x20] // "FIT "
    static let fitEpoch: TimeInterval = 631065600 // 1989-12-31 00:00:00 UTC

    // Global message numbers
    static let globalMessageRecord: UInt16 = 20

    // Record field numbers
    static let fieldTimestamp: UInt8 = 253
    static let fieldPositionLat: UInt8 = 0
    static let fieldPositionLong: UInt8 = 1
    static let fieldAltitude: UInt8 = 2
    static let fieldDistance: UInt8 = 5
    static let fieldSpeed: UInt8 = 6
    static let fieldHeartRate: UInt8 = 3
    static let fieldCadence: UInt8 = 4
    static let fieldEnhancedAltitude: UInt8 = 78
    static let fieldEnhancedSpeed: UInt8 = 73

    // Scaling factors
    static let altitudeScale: Double = 5.0
    static let altitudeOffset: Double = 500.0
    static let distanceScale: Double = 100.0
    static let speedScale: Double = 1000.0

    // Sentinel values
    static let invalidCoordinate: Int32 = 0x7FFFFFFF
    static let invalidUint16: UInt16 = 0xFFFF
    static let invalidUint32: UInt32 = 0xFFFFFFFF
    static let invalidUint8: UInt8 = 0xFF

    /// Parse FIT binary data and return record messages.
    public static func parse(data: Data) throws -> [FITRecordMessage] {
        guard !data.isEmpty else {
            throw FITError.emptyFile
        }

        var offset = 0

        // Parse header
        let dataEndOffset = try parseHeader(data: data, offset: &offset)

        // Parse data records
        var definitions: [UInt8: FITDefinitionMessage] = [:]
        var records: [FITRecordMessage] = []

        while offset < dataEndOffset {
            let recordHeader = data[offset]
            offset += 1

            // Check for compressed timestamp header (bit 7 set)
            if recordHeader & 0x80 != 0 {
                throw FITError.corruptedData("Compressed timestamp records are not supported")
            }

            // Bit 6: 0=data message, 1=definition message
            let isDefinition = (recordHeader & 0x40) != 0
            let localType = recordHeader & 0x0F

            if isDefinition {
                // Definition message
                let def = try parseDefinition(
                    data: data,
                    offset: &offset,
                    dataEndOffset: dataEndOffset,
                    localType: localType
                )
                definitions[localType] = def
            } else {
                // Data message
                guard let def = definitions[localType] else {
                    throw FITError.missingDefinition(localType)
                }

                if def.globalMessageNumber == globalMessageRecord {
                    let record = try parseRecordMessage(
                        data: data,
                        offset: &offset,
                        dataEndOffset: dataEndOffset,
                        definition: def
                    )
                    records.append(record)
                } else {
                    // Skip non-record messages
                    let dataSize = def.fields.reduce(0) { $0 + Int($1.size) }
                    guard offset + dataSize <= dataEndOffset else {
                        throw FITError.unexpectedEndOfFile
                    }
                    offset += dataSize
                }
            }
        }

        return records
    }

    /// Parse FIT file header. Returns the exclusive end offset for data records.
    private static func parseHeader(data: Data, offset: inout Int) throws -> Int {
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

        let dataSize = Int(readUInt32(data: data[4..<8], littleEndian: true))
        let dataStart = headerLength
        let dataEnd = dataStart + dataSize
        guard data.count >= dataEnd + 2 else {
            throw FITError.unexpectedEndOfFile
        }

        offset = headerLength
        return dataEnd
    }

    /// Parse a definition message.
    private static func parseDefinition(
        data: Data,
        offset: inout Int,
        dataEndOffset: Int,
        localType: UInt8
    ) throws -> FITDefinitionMessage {
        guard offset + 5 <= dataEndOffset else {
            throw FITError.unexpectedEndOfFile
        }

        let _ = data[offset] // reserved byte
        offset += 1

        let architecture = data[offset]
        offset += 1

        // Global message number (2 bytes)
        let globalMessageNumber: UInt16
        if architecture == 0 {
            // Little-endian
            globalMessageNumber = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            // Big-endian
            globalMessageNumber = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
        offset += 2

        let fieldCount = Int(data[offset])
        offset += 1

        var fields: [FITFieldDefinition] = []
        for _ in 0..<fieldCount {
            guard offset + 3 <= dataEndOffset else {
                throw FITError.unexpectedEndOfFile
            }

            let fieldNum = data[offset]
            let fieldSize = data[offset + 1]
            let fieldType = data[offset + 2]
            offset += 3

            fields.append(FITFieldDefinition(
                fieldNumber: fieldNum,
                size: fieldSize,
                type: fieldType
            ))
        }

        return FITDefinitionMessage(
            architecture: architecture,
            globalMessageNumber: globalMessageNumber,
            fields: fields
        )
    }

    /// Parse a record (activity) message.
    private static func parseRecordMessage(
        data: Data,
        offset: inout Int,
        dataEndOffset: Int,
        definition: FITDefinitionMessage
    ) throws -> FITRecordMessage {
        var record = FITRecordMessage()
        let isLittleEndian = definition.architecture == 0

        for field in definition.fields {
            guard offset + Int(field.size) <= dataEndOffset else {
                throw FITError.unexpectedEndOfFile
            }

            let fieldData = data[offset..<(offset + Int(field.size))]

            switch field.fieldNumber {
            case fieldTimestamp:
                if field.size >= 4 {
                    record.timestamp = readUInt32(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldPositionLat:
                if field.size >= 4 {
                    record.positionLat = readInt32(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldPositionLong:
                if field.size >= 4 {
                    record.positionLong = readInt32(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldAltitude:
                if field.size >= 2 {
                    record.altitude = readUInt16(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldEnhancedAltitude:
                if field.size >= 2 {
                    record.enhancedAltitude = readUInt16(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldDistance:
                if field.size >= 4 {
                    record.distance = readUInt32(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldSpeed:
                if field.size >= 2 {
                    record.speed = readUInt16(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldEnhancedSpeed:
                if field.size >= 2 {
                    record.enhancedSpeed = readUInt16(data: fieldData, littleEndian: isLittleEndian)
                }
            case fieldHeartRate:
                if field.size >= 1 {
                    record.heartRate = fieldData[fieldData.startIndex]
                }
            case fieldCadence:
                if field.size >= 1 {
                    record.cadence = fieldData[fieldData.startIndex]
                }
            default:
                break // Skip unknown fields
            }

            offset += Int(field.size)
        }

        return record
    }

    // MARK: - Binary Reading Helpers

    private static func readUInt16(data: Data.SubSequence, littleEndian: Bool) -> UInt16 {
        let bytes = Array(data.prefix(2))
        if littleEndian {
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        } else {
            return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        }
    }

    private static func readInt32(data: Data.SubSequence, littleEndian: Bool) -> Int32 {
        Int32(bitPattern: readUInt32(data: data, littleEndian: littleEndian))
    }

    private static func readUInt32(data: Data.SubSequence, littleEndian: Bool) -> UInt32 {
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
        (Double(scaled) / altitudeScale) - altitudeOffset
    }

    /// Convert scaled distance to meters.
    public static func scaledDistanceToMeters(_ scaled: UInt32) -> Double {
        Double(scaled) / distanceScale
    }

    /// Convert scaled speed to m/s.
    public static func scaledSpeedToMPS(_ scaled: UInt16) -> Double {
        Double(scaled) / speedScale
    }
}
