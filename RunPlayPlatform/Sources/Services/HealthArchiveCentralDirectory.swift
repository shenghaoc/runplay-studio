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
        let fileLength = try file.seekToEnd()
        func read(at offset: UInt64, count: Int) throws -> [UInt8] {
            guard offset <= fileLength, UInt64(count) <= fileLength - offset else {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw AppleHealthArchiveError.invalidCentralDirectory }
            return Array(data)
        }

        guard fileLength >= 22 else { throw AppleHealthArchiveError.invalidCentralDirectory }
        let tailLength = Int(min(fileLength, 22 + UInt64(UInt16.max)))
        let tailOffset = fileLength - UInt64(tailLength)
        let tail = try read(at: tailOffset, count: tailLength)
        guard let endIndex = stride(from: tail.count - 22, through: 0, by: -1).first(where: {
            integer(tail, at: $0, width: 4) == 0x06054b50
                && $0 + 22 + Int(integer(tail, at: $0 + 20, width: 2)) == tail.count
        }) else { throw AppleHealthArchiveError.invalidCentralDirectory }
        let endOffset = tailOffset + UInt64(endIndex)
        guard integer(tail, at: endIndex + 4, width: 2) == 0,
              integer(tail, at: endIndex + 6, width: 2) == 0 else {
            throw AppleHealthArchiveError.invalidCentralDirectory
        }
        var count = integer(tail, at: endIndex + 10, width: 2)
        var size = integer(tail, at: endIndex + 12, width: 4)
        var offset = integer(tail, at: endIndex + 16, width: 4)
        if endOffset >= 20 {
            let locator = try read(at: endOffset - 20, count: 20)
            if integer(locator, at: 0, width: 4) == 0x07064b50 {
                guard integer(locator, at: 4, width: 4) == 0,
                      integer(locator, at: 16, width: 4) == 1 else {
                    throw AppleHealthArchiveError.invalidCentralDirectory
                }
                let record = try read(at: integer(locator, at: 8, width: 8), count: 56)
                guard integer(record, at: 0, width: 4) == 0x06064b50,
                      integer(record, at: 4, width: 8) >= 44,
                      integer(record, at: 16, width: 4) == 0,
                      integer(record, at: 20, width: 4) == 0,
                      integer(record, at: 24, width: 8) == integer(record, at: 32, width: 8) else {
                    throw AppleHealthArchiveError.invalidCentralDirectory
                }
                count = integer(record, at: 32, width: 8)
                size = integer(record, at: 40, width: 8)
                offset = integer(record, at: 48, width: 8)
            } else if count == 0xffff || size == 0xffffffff || offset == 0xffffffff {
                throw AppleHealthArchiveError.invalidCentralDirectory
            }
        }
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
            let header = try read(at: offset, count: 46)
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
            let name = try read(at: offset + 46, count: nameLength)
            let utf8 = (integer(header, at: 8, width: 2) & 0x0800) != 0
            let encoding = utf8 ? String.Encoding.utf8 : String.Encoding(rawValue:
                CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400)))
            if String(bytes: name, encoding: encoding) == entryPath {
                let declared = integer(header, at: 24, width: 4)
                if declared != 0xffffffff { return declared }
                let extra = try read(at: offset + 46 + UInt64(nameLength), count: extraLength)
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
            offset += length
        }
        throw AppleHealthArchiveError.invalidCentralDirectory
    }

    private static func integer(_ bytes: [UInt8], at offset: Int, width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | (UInt64(bytes[offset + $1]) << (8 * $1)) }
    }
}
