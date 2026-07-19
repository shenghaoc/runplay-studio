import XCTest
import zlib
@testable import RunPlayPlatform
import RunPlayCore

final class GZIPDecoderTests: XCTestCase {

    private func gzip(_ payload: Data) -> Data {
        // Build a minimal GZIP member using zlib compress with gzip wrapper.
        // Use compress2 is zlib format; build manually via deflateInit2 with windowBits 15+16.
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        precondition(initStatus == Z_OK)
        defer { deflateEnd(&stream) }

        var output = Data(count: payload.count + 64)
        return payload.withUnsafeBytes { inBuf in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inBuf.bindMemory(to: UInt8.self).baseAddress!)
            stream.avail_in = uInt(payload.count)
            return output.withUnsafeMutableBytes { outBuf in
                stream.next_out = outBuf.bindMemory(to: UInt8.self).baseAddress!
                stream.avail_out = uInt(outBuf.count)
                let status = deflate(&stream, Z_FINISH)
                precondition(status == Z_STREAM_END)
                let written = outBuf.count - Int(stream.avail_out)
                return Data(outBuf.bindMemory(to: UInt8.self).prefix(written))
            }
        }
    }

    func testValidRoundTrip() throws {
        let original = Data("hello fit-like payload for gzip tests".utf8)
        let compressed = gzip(original)
        let decoded = try GZIPDecoder().decode(compressed)
        XCTAssertEqual(decoded, original)
    }

    func testInvalidMagic() {
        let data = Data([0x00, 0x00, 0x00])
        XCTAssertThrowsError(try GZIPDecoder().decode(data)) { error in
            let e = error as? GZIPDecoderError
            XCTAssertTrue(e == .invalidMagic || e == .truncatedHeader)
        }
    }

    func testTruncatedHeader() {
        let data = Data([0x1f, 0x8b, 0x08])
        XCTAssertThrowsError(try GZIPDecoder().decode(data)) { error in
            XCTAssertEqual(error as? GZIPDecoderError, .truncatedHeader)
        }
    }

    func testUnsupportedCompressionMethod() {
        // ID1 ID2 CM=0 FLG MTIME XFL OS + fake trailer
        var data = Data([0x1f, 0x8b, 0x00, 0x00])
        data.append(contentsOf: [0,0,0,0, 0, 0])
        data.append(contentsOf: [0,0,0,0, 0,0,0,0])
        XCTAssertThrowsError(try GZIPDecoder().decode(data)) { error in
            XCTAssertEqual(error as? GZIPDecoderError, .unsupportedCompressionMethod)
        }
    }

    func testOutputLimit() {
        let original = Data(repeating: 0x41, count: 2000)
        let compressed = gzip(original)
        let decoder = GZIPDecoder(maxOutputBytes: 100)
        XCTAssertThrowsError(try decoder.decode(compressed)) { error in
            XCTAssertEqual(error as? GZIPDecoderError, .outputLimitExceeded)
        }
    }

    func testCRCMismatch() throws {
        var compressed = gzip(Data("abc".utf8))
        // Flip a trailer CRC byte
        compressed[compressed.count - 5] ^= 0xFF
        XCTAssertThrowsError(try GZIPDecoder().decode(compressed)) { error in
            XCTAssertEqual(error as? GZIPDecoderError, .crcMismatch)
        }
    }

    func testCancellation() {
        let original = Data(repeating: 0x42, count: 50_000)
        let compressed = gzip(original)
        let decoder = GZIPDecoder(cancellationCheckStride: 1)
        XCTAssertThrowsError(try decoder.decode(compressed, isCancelled: { true })) { error in
            XCTAssertEqual(error as? GZIPDecoderError, .cancelled)
        }
    }
}
