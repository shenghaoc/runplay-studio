import XCTest
import RunPlayCore
@testable import RunPlayPlatform

/// The real SHA-256 provider that core FIT session identity depends on.
///
/// Core tests inject a deterministic stand-in so they stay Linux-clean; this
/// suite pins the production conformance.
final class ContentDigestTests: XCTestCase {

    private let digest = CryptoKitContentDigest()

    func testMatchesKnownSHA256Vector() {
        // NIST test vector for "abc".
        XCTAssertEqual(
            digest.sha256Hex(of: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testEmptyInputMatchesKnownVector() {
        XCTAssertEqual(
            digest.sha256Hex(of: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testDigestIsLowercaseHexOfFixedLength() {
        let hex = digest.sha256Hex(of: Data([0x00, 0xFF, 0x10]))
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
    }

    func testDigestMatchesContentHasher() {
        let payload = Data("runplay".utf8)
        XCTAssertEqual(digest.sha256Hex(of: payload), ContentHasher.sha256Hex(of: payload))
    }

    // MARK: - FIT session identity through the production digest

    func testSiblingSessionsGetDistinctIdentitiesWithRealSHA256() {
        var first = FITSessionMessage()
        first.startTime = 1_000
        first.timestamp = 2_000
        first.sport = FITSport.running.rawValue

        var second = first
        second.startTime = 3_000
        second.timestamp = 4_000

        let container = digest.sha256Hex(of: Data("container".utf8))
        let firstID = FITSessionIdentity.providerActivityID(
            containerSHA256: container,
            sourceIndex: 0,
            session: first,
            digest: digest
        )
        let secondID = FITSessionIdentity.providerActivityID(
            containerSHA256: container,
            sourceIndex: 1,
            session: second,
            digest: digest
        )

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(firstID.hasPrefix("fit-session-v1:"))
        XCTAssertEqual(firstID.count, "fit-session-v1:".count + 64)
    }

    func testIdenticalSessionsDifferOnlyBySourceOrdinal() {
        var session = FITSessionMessage()
        session.startTime = 1_000
        session.timestamp = 2_000

        let container = String(repeating: "0", count: 64)
        let atIndexZero = FITSessionIdentity.providerActivityID(
            containerSHA256: container,
            sourceIndex: 0,
            session: session,
            digest: digest
        )
        let atIndexOne = FITSessionIdentity.providerActivityID(
            containerSHA256: container,
            sourceIndex: 1,
            session: session,
            digest: digest
        )
        XCTAssertNotEqual(atIndexZero, atIndexOne)
    }

    func testIdentityContainsNoPathOrRawTimestamp() {
        var session = FITSessionMessage()
        session.startTime = 1_234_567
        session.timestamp = 1_234_667

        let id = FITSessionIdentity.providerActivityID(
            containerSHA256: String(repeating: "a", count: 64),
            sourceIndex: 0,
            session: session,
            digest: digest
        )
        XCTAssertFalse(id.contains("/"))
        XCTAssertFalse(id.contains("1234567"))
        XCTAssertFalse(id.contains("@"))
    }

    func testIdentityIsStableAcrossRepeatedCalls() {
        var session = FITSessionMessage()
        session.startTime = 500
        session.timestamp = 900
        session.firstLapIndex = 0
        session.numberOfLaps = 3

        let container = String(repeating: "f", count: 64)
        let first = FITSessionIdentity.providerActivityID(
            containerSHA256: container,
            sourceIndex: 2,
            session: session,
            digest: digest
        )
        let second = FITSessionIdentity.providerActivityID(
            containerSHA256: container,
            sourceIndex: 2,
            session: session,
            digest: digest
        )
        XCTAssertEqual(first, second)
    }
}
