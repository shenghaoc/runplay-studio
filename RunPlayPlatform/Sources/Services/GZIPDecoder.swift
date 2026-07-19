import Foundation
import zlib
import RunPlayCore

/// Errors from the narrowly scoped GZIP envelope decoder.
public enum GZIPDecoderError: Error, LocalizedError, Equatable, Sendable {
    case truncatedHeader
    case invalidMagic
    case unsupportedCompressionMethod
    case encryptedOrUnsupportedFlags
    case truncatedData
    case crcMismatch
    case sizeMismatch
    case outputLimitExceeded
    case inflateFailed(String)
    case concatenatedMembersNotSupported
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .truncatedHeader: return "GZIP header is truncated"
        case .invalidMagic: return "Not a GZIP stream"
        case .unsupportedCompressionMethod: return "Unsupported GZIP compression method"
        case .encryptedOrUnsupportedFlags: return "Encrypted or unsupported GZIP flags"
        case .truncatedData: return "GZIP stream is truncated"
        case .crcMismatch: return "GZIP CRC32 mismatch"
        case .sizeMismatch: return "GZIP uncompressed size mismatch"
        case .outputLimitExceeded: return "GZIP output exceeds size limit"
        case .inflateFailed(let detail): return "GZIP inflate failed: \(detail)"
        case .concatenatedMembersNotSupported: return "Concatenated GZIP members are not supported"
        case .cancelled: return "GZIP decoding was cancelled"
        }
    }
}

/// Narrow GZIP member decoder for Strava activity wrappers (`.fit.gz`, etc.).
///
/// Validates the header, rejects encryption/unsupported flags, inflates with
/// zlib, verifies CRC32 and ISIZE, enforces output limits, and supports
/// cooperative cancellation. Does not recursively decompress. Concatenated
/// members after the first are rejected.
public struct GZIPDecoder: Sendable {

    public var maxOutputBytes: Int
    public var cancellationCheckStride: Int

    public init(
        maxOutputBytes: Int = Int(WorkoutArchiveSecurityPolicy.default.maxUncompressedEntryBytes),
        cancellationCheckStride: Int = WorkoutArchiveSecurityPolicy.default.cancellationCheckStride
    ) {
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.cancellationCheckStride = max(1, cancellationCheckStride)
    }

    /// Decompress a single GZIP member.
    public func decode(
        _ data: Data,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        if isCancelled() { throw GZIPDecoderError.cancelled }
        guard data.count >= 18 else { throw GZIPDecoderError.truncatedHeader }

        let bytes = [UInt8](data)
        var offset = 0

        func need(_ n: Int) throws {
            if offset + n > bytes.count { throw GZIPDecoderError.truncatedHeader }
        }
        func readU8() throws -> UInt8 {
            try need(1)
            let v = bytes[offset]
            offset += 1
            return v
        }
        func readU16LE() throws -> UInt16 {
            try need(2)
            let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return v
        }

        let id1 = try readU8()
        let id2 = try readU8()
        guard id1 == 0x1f, id2 == 0x8b else { throw GZIPDecoderError.invalidMagic }

        let cm = try readU8()
        guard cm == 8 else { throw GZIPDecoderError.unsupportedCompressionMethod }

        let flg = try readU8()
        // MTIME(4) + XFL(1) + OS(1)
        try need(6)
        offset += 6

        let fhcrc: UInt8 = 0x02
        let fextra: UInt8 = 0x04
        let fname: UInt8 = 0x08
        let fcomment: UInt8 = 0x10
        let ftext: UInt8 = 0x01
        let allowed = ftext | fhcrc | fextra | fname | fcomment
        if flg & ~allowed != 0 {
            throw GZIPDecoderError.encryptedOrUnsupportedFlags
        }

        if flg & fextra != 0 {
            let xlen = Int(try readU16LE())
            try need(xlen)
            offset += xlen
        }
        if flg & fname != 0 {
            while true {
                let b = try readU8()
                if b == 0 { break }
            }
        }
        if flg & fcomment != 0 {
            while true {
                let b = try readU8()
                if b == 0 { break }
            }
        }
        if flg & fhcrc != 0 {
            _ = try readU16LE()
        }

        // Trailer is last 8 bytes of the member. Compressed payload is between
        // header end and trailer. For a single member, trailer is end of data.
        guard bytes.count >= offset + 8 else { throw GZIPDecoderError.truncatedData }
        let trailerIndex = bytes.count - 8
        guard offset <= trailerIndex else { throw GZIPDecoderError.truncatedData }

        let compressed = Array(bytes[offset..<trailerIndex])
        let output = try inflateRaw(
            compressed,
            maxOutput: maxOutputBytes,
            isCancelled: isCancelled
        )

        let crcExpected = UInt32(bytes[trailerIndex])
            | (UInt32(bytes[trailerIndex + 1]) << 8)
            | (UInt32(bytes[trailerIndex + 2]) << 16)
            | (UInt32(bytes[trailerIndex + 3]) << 24)
        let isize = UInt32(bytes[trailerIndex + 4])
            | (UInt32(bytes[trailerIndex + 5]) << 8)
            | (UInt32(bytes[trailerIndex + 6]) << 16)
            | (UInt32(bytes[trailerIndex + 7]) << 24)

        let crcActual: UInt32 = output.withUnsafeBytes { buf in
            guard let p = buf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return UInt32(crc32(0, p, uInt(output.count)))
        }
        if crcActual != crcExpected {
            throw GZIPDecoderError.crcMismatch
        }
        if UInt32(truncatingIfNeeded: output.count) != isize {
            throw GZIPDecoderError.sizeMismatch
        }

        // Single-member policy: trailer must be the end of the buffer.
        // (We always use end-of-data as trailer; concatenated members would
        // mean the inflate stream ends earlier with leftover compressed bytes
        // that are not a valid single-member layout. Detect via inflate
        // not consuming all compressed input.)
        // inflateRaw already requires full consumption.

        return output
    }

    private func inflateRaw(
        _ compressed: [UInt8],
        maxOutput: Int,
        isCancelled: () -> Bool
    ) throws -> Data {
        if compressed.isEmpty {
            throw GZIPDecoderError.truncatedData
        }

        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw GZIPDecoderError.inflateFailed("inflateInit2 (\(status))")
        }
        defer { inflateEnd(&stream) }

        return try compressed.withUnsafeBufferPointer { inBuf in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBuf.baseAddress!)
            stream.avail_in = uInt(inBuf.count)

            var output = Data()
            output.reserveCapacity(min(maxOutput, max(inBuf.count * 2, 4096)))
            let chunkSize = 65_536
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            var iterations = 0

            while true {
                iterations += 1
                if iterations % max(1, cancellationCheckStride) == 0, isCancelled() {
                    throw GZIPDecoderError.cancelled
                }

                var hitOutputLimit = false
                status = chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress!
                    stream.avail_out = uInt(chunkSize)
                    let s = inflate(&stream, Z_NO_FLUSH)
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        if output.count > maxOutput - produced {
                            hitOutputLimit = true
                            return s
                        }
                        output.append(outBuf.baseAddress!, count: produced)
                    }
                    return s
                }

                if hitOutputLimit || output.count > maxOutput {
                    throw GZIPDecoderError.outputLimitExceeded
                }

                switch status {
                case Z_STREAM_END:
                    if stream.avail_in != 0 {
                        throw GZIPDecoderError.concatenatedMembersNotSupported
                    }
                    return output
                case Z_OK:
                    if stream.avail_out == uInt(chunkSize), stream.avail_in == 0 {
                        // No progress.
                        throw GZIPDecoderError.truncatedData
                    }
                    continue
                case Z_BUF_ERROR:
                    if stream.avail_in == 0 {
                        throw GZIPDecoderError.truncatedData
                    }
                    continue
                default:
                    throw GZIPDecoderError.inflateFailed("inflate status \(status)")
                }
            }
        }
    }
}
