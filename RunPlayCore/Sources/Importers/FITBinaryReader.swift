import Foundation

/// Low-level binary reader for FIT data streams.
///
/// Reads typed values from byte data respecting FIT base types and endianness.
struct FITBinaryReader {
    private let data: Data
    private(set) var offset: Int
    private let endOffset: Int
    private let littleEndian: Bool

    init(data: Data, offset: Int, endOffset: Int, littleEndian: Bool) {
        self.data = data
        self.offset = offset
        self.endOffset = endOffset
        self.littleEndian = littleEndian
    }

    /// Whether there are remaining bytes to read.
    var hasRemainingBytes: Bool {
        offset < endOffset
    }

    /// Number of bytes remaining.
    var remainingBytes: Int {
        max(0, endOffset - offset)
    }

    // MARK: - Raw Byte Reading

    /// Read a single byte.
    mutating func readUInt8() throws -> UInt8 {
        guard offset < endOffset else {
            throw FITError.unexpectedEndOfFile
        }
        let value = data[offset]
        offset += 1
        return value
    }

    /// Read a signed byte.
    mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    /// Skip `count` bytes.
    mutating func skip(_ count: Int) throws {
        guard offset + count <= endOffset else {
            throw FITError.unexpectedEndOfFile
        }
        offset += count
    }

    // MARK: - Multi-byte Reading

    /// Read a UInt16 respecting endianness.
    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= endOffset else {
            throw FITError.unexpectedEndOfFile
        }
        let value: UInt16
        if littleEndian {
            value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        } else {
            value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
        offset += 2
        return value
    }

    /// Read a Int16 respecting endianness.
    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    /// Read a UInt32 respecting endianness.
    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= endOffset else {
            throw FITError.unexpectedEndOfFile
        }
        let value: UInt32
        if littleEndian {
            value = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        } else {
            value = (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }
        offset += 4
        return value
    }

    /// Read a Int32 respecting endianness.
    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    /// Read a UInt64 respecting endianness.
    mutating func readUInt64() throws -> UInt64 {
        guard offset + 8 <= endOffset else {
            throw FITError.unexpectedEndOfFile
        }
        var value: UInt64 = 0
        if littleEndian {
            for i in 0..<8 {
                value |= UInt64(data[offset + i]) << (i * 8)
            }
        } else {
            for i in 0..<8 {
                value |= UInt64(data[offset + (7 - i)]) << (i * 8)
            }
        }
        offset += 8
        return value
    }

    /// Read a Int64 respecting endianness.
    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    /// Read a Float32 respecting endianness.
    mutating func readFloat32() throws -> Float32 {
        let bits = try readUInt32()
        return Float32(bitPattern: bits)
    }

    /// Read a Float64 respecting endianness.
    mutating func readFloat64() throws -> Float64 {
        let bits = try readUInt64()
        return Float64(bitPattern: bits)
    }

    /// Read raw bytes of specified count.
    mutating func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= endOffset else {
            throw FITError.unexpectedEndOfFile
        }
        let bytes = data[offset..<(offset + count)]
        offset += count
        return Data(bytes)
    }

    // MARK: - Base Type Value Reading

    /// Read a value for a FIT base type from the current offset.
    /// Returns the value as an appropriate Swift type, or nil if the value
    /// matches the base type's invalid sentinel.
    mutating func readBaseTypeValue(
        baseType: FITBaseType,
        fieldSize: Int
    ) throws -> FITFieldValue {
        switch baseType {
        case .enum:
            let raw = try readUInt8()
            return raw == 0xFF ? .invalid : .uint8(raw)

        case .sint8:
            let raw = try readInt8()
            return raw == 0x7F ? .invalid : .int8(raw)

        case .uint8:
            let raw = try readUInt8()
            return raw == 0xFF ? .invalid : .uint8(raw)

        case .uint8z:
            let raw = try readUInt8()
            return raw == 0x00 ? .invalid : .uint8(raw)

        case .sint16:
            let raw = try readInt16()
            return raw == 0x7FFF ? .invalid : .int16(raw)

        case .uint16:
            let raw = try readUInt16()
            return raw == 0xFFFF ? .invalid : .uint16(raw)

        case .uint16z:
            let raw = try readUInt16()
            return raw == 0x0000 ? .invalid : .uint16(raw)

        case .sint32:
            let raw = try readInt32()
            return raw == 0x7FFFFFFF ? .invalid : .int32(raw)

        case .uint32:
            let raw = try readUInt32()
            return raw == 0xFFFFFFFF ? .invalid : .uint32(raw)

        case .uint32z:
            let raw = try readUInt32()
            return raw == 0x00000000 ? .invalid : .uint32(raw)

        case .sint64:
            let raw = try readInt64()
            return raw == 0x7FFFFFFFFFFFFFFF ? .invalid : .int64(raw)

        case .uint64:
            let raw = try readUInt64()
            return raw == 0xFFFFFFFFFFFFFFFF ? .invalid : .uint64(raw)

        case .uint64z:
            let raw = try readUInt64()
            return raw == 0 ? .invalid : .uint64(raw)

        case .float32:
            let raw = try readFloat32()
            return raw.isNaN ? .invalid : .float32(raw)

        case .float64:
            let raw = try readFloat64()
            return raw.isNaN ? .invalid : .float64(raw)

        case .string:
            // String fields: read up to fieldSize bytes, look for null terminator
            let bytes = try readBytes(fieldSize)
            var stringBytes: [UInt8] = []
            for byte in bytes {
                if byte == 0 { break }
                stringBytes.append(byte)
            }
            guard !stringBytes.isEmpty else { return .invalid }
            guard let str = String(bytes: stringBytes, encoding: .utf8) else {
                return .invalid
            }
            return .string(str)

        case .byte:
            let bytes = try readBytes(fieldSize)
            // Check if all bytes are 0xFF (invalid)
            if bytes.allSatisfy({ $0 == 0xFF }) {
                return .invalid
            }
            return .bytes(bytes)
        }
    }

    /// Read an array of base type values from a single field.
    mutating func readBaseTypeArray(
        baseType: FITBaseType,
        fieldSize: Int
    ) throws -> [FITFieldValue] {
        let elementSize = baseType == .string ? fieldSize : baseType.byteSize
        guard elementSize > 0 else {
            throw FITError.corruptedData("Zero element size for base type")
        }

        if baseType == .string {
            // String is always a single value
            return [try readBaseTypeValue(baseType: baseType, fieldSize: fieldSize)]
        }

        let count = fieldSize / elementSize
        guard count > 0 else {
            // Skip the field entirely if the size doesn't align
            try skip(fieldSize)
            return []
        }

        var values: [FITFieldValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try readBaseTypeValue(baseType: baseType, fieldSize: elementSize))
        }

        // Skip any remaining bytes that don't form a complete element
        let remainder = fieldSize % elementSize
        if remainder > 0 {
            try skip(remainder)
        }

        return values
    }
}

/// FIT field value decoded from binary data.
enum FITFieldValue: Sendable {
    case uint8(UInt8)
    case int8(Int8)
    case uint16(UInt16)
    case int16(Int16)
    case uint32(UInt32)
    case int32(Int32)
    case uint64(UInt64)
    case int64(Int64)
    case float32(Float32)
    case float64(Float64)
    case string(String)
    case bytes(Data)
    case invalid

    /// Extract a UInt32 value if valid.
    var uint32Value: UInt32? {
        switch self {
        case .uint32(let v): return v
        case .uint16(let v): return UInt32(v)
        case .uint8(let v): return UInt32(v)
        default: return nil
        }
    }

    /// Extract an Int32 value if valid.
    var int32Value: Int32? {
        switch self {
        case .int32(let v): return v
        case .int16(let v): return Int32(v)
        case .int8(let v): return Int32(v)
        default: return nil
        }
    }

    /// Extract a UInt16 value if valid.
    var uint16Value: UInt16? {
        switch self {
        case .uint16(let v): return v
        case .uint8(let v): return UInt16(v)
        default: return nil
        }
    }

    /// Extract a UInt8 value if valid.
    var uint8Value: UInt8? {
        switch self {
        case .uint8(let v): return v
        default: return nil
        }
    }

    /// Extract an Int8 value if valid.
    var int8Value: Int8? {
        switch self {
        case .int8(let v): return v
        default: return nil
        }
    }

    /// Extract a string value if valid.
    var stringValue: String? {
        switch self {
        case .string(let v): return v
        default: return nil
        }
    }

    /// Extract a Float64 value if valid.
    var float64Value: Double? {
        switch self {
        case .float64(let v): return v
        case .float32(let v): return Double(v)
        default: return nil
        }
    }
}
