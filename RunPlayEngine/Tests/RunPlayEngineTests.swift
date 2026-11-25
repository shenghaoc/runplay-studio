import RunPlayEngine
import RunPlayEngineTestSupport
import Testing

@Suite struct RunPlayEngineTests {
    @Test func splitMix64SeedZero() {
        var random = SplitMix64(seed: 0)
        #expect(random.next() == 0xe220_a839_7b1d_cdaf)
        #expect(random.next() == 0x6e78_9e6a_a1b9_65f4)
        #expect(random.next() == 0x06c4_5d18_8009_454f)
    }

    @Test func digestUsesLittleEndianBytes() {
        var digest = FNV1a64()
        digest.append(word: UInt16(0x6f66))
        digest.append(byte: 0x6f)
        #expect(digest.value == 0xdcb2_7518_fed9_d577) // FNV-1a-64("foo").
    }

    @Test func comparisonAcceptsMatchingNaNPayloads() {
        let double = Double(bitPattern: 0x7ff8_0000_0000_0001)
        expectEqualBits(double, double)
        let float = Float(bitPattern: 0x7fc0_0001)
        expectEqualBits(float, float)
    }
}
