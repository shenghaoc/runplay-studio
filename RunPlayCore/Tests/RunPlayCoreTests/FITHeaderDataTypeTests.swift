import Foundation
import XCTest
@testable import RunPlayCore

/// The FIT file header's data-type field, pinned against the specification
/// rather than against this repo's own fixtures.
///
/// Why this suite exists: the parser previously expected `"FIT "` (F, I, T,
/// space) while every real FIT file carries `".FIT"` (period, F, I, T). Every
/// fixture builder in the test suite wrote the same wrong bytes, so the whole
/// suite passed while the app could not import a single real FIT file. The
/// bug was invisible precisely because production and fixtures agreed with
/// each other and nothing checked either against the spec.
///
/// These assertions therefore use literal bytes taken from the specification
/// and from a real device file, never `FITParser.fitDataType` or a fixture
/// builder — a test written in terms of the thing under test would have
/// passed before the fix too.
final class FITHeaderDataTypeTests: XCTestCase {

    /// The four bytes as the official SDKs spell them:
    ///  - C SDK   `example-sdk/fit.h:199` — `FIT_UINT8 data_type[4]; // ".FIT"`
    ///  - C++ SDK `src/fit_encode.cpp:118` —
    ///    `memcpy( ( FIT_UINT8 * )&file_header.data_type, ".FIT", 4 );`
    private let specDataType: [UInt8] = [0x2E, 0x46, 0x49, 0x54]

    func testDataTypeConstantMatchesTheSpecification() {
        XCTAssertEqual(
            FITParser.fitDataType,
            specDataType,
            #"FIT header bytes 8..<12 are ".FIT", not "FIT ""#
        )
        XCTAssertEqual(
            String(decoding: specDataType, as: UTF8.self),
            ".FIT"
        )
    }

    /// The specific historical defect: the transposed spelling must not be
    /// accepted, or a corrupt file would parse as valid.
    func testTransposedSpellingIsRejected() {
        let wrong: [UInt8] = [0x46, 0x49, 0x54, 0x20] // "FIT "
        XCTAssertNotEqual(
            FITParser.fitDataType,
            wrong,
            "the pre-fix constant must not come back"
        )
    }

    /// A header built from real-file bytes must parse. These 12 bytes are the
    /// header of a Garmin-produced activity file: header size 12, protocol
    /// 0x10, profile 0x01FF, then the data-type field.
    func testRealDeviceHeaderShapeParses() throws {
        var data = Data([0x0C, 0x10, 0xFF, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // data size 0
        data.append(contentsOf: specDataType)
        // A zero-length body still needs its trailing file CRC.
        let crc = FITParser.crc16(over: data[0..<12])
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8((crc >> 8) & 0xFF))

        var offset = 0
        let end = try FITParser.parseHeader(data: data, offset: &offset)
        XCTAssertEqual(offset, 12)
        XCTAssertEqual(end, 12)
    }

    /// And a header carrying the old wrong spelling must be refused, so a
    /// regression shows up as a rejection rather than as silent acceptance.
    func testHeaderWithTransposedSpellingIsRefused() {
        var data = Data([0x0C, 0x10, 0xFF, 0x01])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x46, 0x49, 0x54, 0x20]) // "FIT "
        let crc = FITParser.crc16(over: data[0..<12])
        data.append(UInt8(crc & 0xFF))
        data.append(UInt8((crc >> 8) & 0xFF))

        var offset = 0
        XCTAssertThrowsError(try FITParser.parseHeader(data: data, offset: &offset)) { error in
            guard case FITError.invalidDataType = error else {
                return XCTFail("expected .invalidDataType, got \(error)")
            }
        }
    }

    // MARK: - Fixture writers emit the specified bytes

    /// FIT file-header layout (C SDK `example-sdk/fit.h:193-201`): a 12- or
    /// 14-byte header of `header_size`, `protocol_version`, `profile_version`,
    /// `data_size`, then `data_type[4]` — bytes 8..<12 — and an optional
    /// header `crc`. The data-type bytes are the ASCII string ".FIT".
    ///
    /// Each fixture writer that emits a header is pinned here against those
    /// literal bytes. This is the check the original bug lacked: when all
    /// three writers spelled the magic wrong together with the parser, every
    /// fixture-based test still passed. Reading the bytes back out of a built
    /// container — not consulting `FITParser.fitDataType` — is what makes a
    /// re-convergence fail loudly instead of silently.
    func testMultiSessionFixtureBuilderEmitsSpecifiedDataTypeBytes() throws {
        for (name, data) in [
            ("singleRunningSession", FITMultiSessionFixtureBuilder.singleRunningSession()),
            ("twoSequentialRuns", FITMultiSessionFixtureBuilder.twoSequentialRuns()),
            ("legacyNoSessions", FITMultiSessionFixtureBuilder.legacyNoSessions())
        ] {
            XCTAssertEqual(
                Array(data[8..<12]),
                specDataType,
                "\(name) must emit data-type bytes 8..<12 as \".FIT\""
            )
            // The writer emits the 14-byte header shape, so the bytes sit
            // behind a declared length that itself must stay at 12 or 14.
            XCTAssertTrue(data[0] == 12 || data[0] == 14, "\(name) header size")
        }
    }
}
