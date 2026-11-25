import Foundation
import CoreFoundation

/// Reads the XML entry's authoritative size without consulting its data descriptor.
/// ZIPFoundation 0.9.20's public Entry.uncompressedSize can prefer the descriptor.
enum HealthArchiveCentralDirectory {
    static func uncompressedSize(
        at url: URL,
        entryPath: String,
        maximumEntries: Int
    ) throws -> UInt64 {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let reader = BoundedReader(file: file, fileLength: try file.seekToEnd())

        let (endOffset, endRecord) = try endOfCentralDirectory(reader)
        let directory = try directoryLocation(reader, endOffset: endOffset, endRecord: endRecord)
        let count = directory.count
        var offset = directory.offset
        let size = directory.size
        guard count <= UInt64(max(0, maximumEntries)) else {
            throw AppleHealthArchiveError.tooManyEntries(limit: maximumEntries)
        }
        guard offset <= endOffset, size <= endOffset - offset else {
            throw AppleHealthArchiveError.invalidCentralDirectory
        }
        let directoryEnd = offset + size
        for _ in 0..<count {
            guard offset <= directoryEnd, directoryEnd - offset >= 46 else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            let header = try reader.read(at: offset, count: 46)
            guard integer(header, at: 0, width: 4) == 0x02014b50 else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            let nameLength = Int(integer(header, at: 28, width: 2))
            let extraLength = Int(integer(header, at: 30, width: 2))
            let commentLength = Int(integer(header, at: 32, width: 2))
            let length = UInt64(46 + nameLength + extraLength + commentLength)
            guard length <= directoryEnd - offset else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            let name = try reader.read(at: offset + 46, count: nameLength)
            if entryName(name, header: header) == entryPath {
                let declared = integer(header, at: 24, width: 4)
                if declared != 0xffffffff { return declared }
                let extra = try reader.read(at: offset + 46 + UInt64(nameLength), count: extraLength)
                return try zip64UncompressedSize(inExtraField: extra)
            }
            offset += length
        }
        throw AppleHealthArchiveError.invalidCentralDirectory
    }

    /// Reads exact byte ranges that lie wholly inside the file.
    private struct BoundedReader {
        let file: FileHandle
        let fileLength: UInt64

        func read(at offset: UInt64, count: Int) throws -> [UInt8] {
            guard offset <= fileLength, UInt64(count) <= fileLength - offset else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw AppleHealthArchiveError.invalidCentralDirectory }
            return Array(data)
        }
    }

    /// The offset of the end-of-central-directory record, whose comment ends
    /// the file, and the record's bytes. It must describe a single-disk archive.
    private static func endOfCentralDirectory(_ reader: BoundedReader) throws -> (offset: UInt64, record: [UInt8]) {
        let fileLength = reader.fileLength
        guard fileLength >= 22 else { throw AppleHealthArchiveError.invalidCentralDirectory }
        let tailLength = Int(min(fileLength, 22 + UInt64(UInt16.max)))
        let tailOffset = fileLength - UInt64(tailLength)
        let tail = try reader.read(at: tailOffset, count: tailLength)
        guard let endIndex = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            integer(tail, at: $0, width: 4) == 0x06054b50
                && $0 + 22 + Int(integer(tail, at: $0 + 20, width: 2)) == tail.count
        }) else { throw AppleHealthArchiveError.invalidCentralDirectory }
        let endOffset = tailOffset + UInt64(endIndex)
        guard integer(tail, at: endIndex + 4, width: 2) == 0,
              integer(tail, at: endIndex + 6, width: 2) == 0 else {
            throw AppleHealthArchiveError.invalidCentralDirectory
        }
        return (endOffset, Array(tail[endIndex...]))
    }

    /// The central directory's entry count, size and offset: from the
    /// Zip64 end record when a locator precedes the end record, otherwise
    /// from the end record, which must then not carry a Zip64 sentinel.
    private static func directoryLocation(
        _ reader: BoundedReader, endOffset: UInt64, endRecord: [UInt8]
    ) throws -> (count: UInt64, size: UInt64, offset: UInt64) {
        let count = integer(endRecord, at: 10, width: 2)
        let size = integer(endRecord, at: 12, width: 4)
        let offset = integer(endRecord, at: 16, width: 4)
        if endOffset >= 20 {
            let locator = try reader.read(at: endOffset - 20, count: 20)
            if integer(locator, at: 0, width: 4) == 0x07064b50 {
                return try zip64DirectoryLocation(reader, locator: locator)
            } else if count == 0xffff || size == 0xffffffff || offset == 0xffffffff {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
        }
        return (count, size, offset)
    }

    /// The entry count, size and offset of a single-disk Zip64 end record.
    private static func zip64DirectoryLocation(
        _ reader: BoundedReader, locator: [UInt8]
    ) throws -> (count: UInt64, size: UInt64, offset: UInt64) {
        guard integer(locator, at: 4, width: 4) == 0,
              integer(locator, at: 16, width: 4) == 1 else {
            throw AppleHealthArchiveError.invalidCentralDirectory
        }
        let record = try reader.read(at: integer(locator, at: 8, width: 8), count: 56)
        guard integer(record, at: 0, width: 4) == 0x06064b50,
              integer(record, at: 4, width: 8) >= 44,
              integer(record, at: 16, width: 4) == 0,
              integer(record, at: 20, width: 4) == 0,
              integer(record, at: 24, width: 8) == integer(record, at: 32, width: 8) else {
            throw AppleHealthArchiveError.invalidCentralDirectory
        }
        return (
            integer(record, at: 32, width: 8),
            integer(record, at: 40, width: 8),
            integer(record, at: 48, width: 8)
        )
    }

    /// The entry name, decoded as UTF-8 when the header's language flag is
    /// set and as DOS Latin US otherwise.
    private static func entryName(_ name: [UInt8], header: [UInt8]) -> String? {
        let utf8 = (integer(header, at: 8, width: 2) & 0x0800) != 0
        let encoding = utf8 ? String.Encoding.utf8 : String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400)))
        return String(bytes: name, encoding: encoding)
    }

    /// The uncompressed size in the Zip64 extended-information field (tag 1)
    /// of an entry's extra field.
    private static func zip64UncompressedSize(inExtraField extra: [UInt8]) throws -> UInt64 {
        var cursor = 0
        while cursor < extra.count {
            guard extra.count - cursor >= 4 else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            let tag = integer(extra, at: cursor, width: 2)
            let fieldLength = Int(integer(extra, at: cursor + 2, width: 2))
            cursor += 4
            guard fieldLength <= extra.count - cursor else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            if tag == 1 {
                guard fieldLength >= 8 else { throw AppleHealthArchiveError.invalidCentralDirectory }
                return integer(extra, at: cursor, width: 8)
            }
            cursor += fieldLength
        }
        throw AppleHealthArchiveError.invalidCentralDirectory
    }

    private static func integer(_ bytes: [UInt8], at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << (8 * $1)) }
    }
}
