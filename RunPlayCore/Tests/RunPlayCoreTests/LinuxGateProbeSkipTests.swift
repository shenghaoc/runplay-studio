import XCTest

// THROWAWAY negative control for the Linux CI gate. Never merge.
final class LinuxGateProbeSkipTests: XCTestCase {
    func testSkipsForAnUnlistedReason() throws {
        throw XCTSkip("PROBE unlisted skip reason: the Linux gate must fail on this")
    }
}
