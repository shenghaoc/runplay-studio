import Testing

/// Deterministic inputs for the engine golden corpora.
package struct SplitMix64 {
    private var state: UInt64

    package init(seed: UInt64) {
        state = seed
    }

    package mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

/// The explicit little-endian encoding makes the digest independent of host byte order.
package struct FNV1a64 {
    private(set) package var value: UInt64 = 0xcbf2_9ce4_8422_2325

    package init() {}

    package mutating func append(byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x0100_0000_01b3
    }

    package mutating func append<Word: FixedWidthInteger>(word: Word) {
        for shift in stride(from: 0, to: Word.bitWidth, by: 8) {
            append(byte: UInt8(truncatingIfNeeded: word >> shift))
        }
    }
}

package func expectEqualBits(_ actual: Double, _ expected: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.bitPattern == expected.bitPattern, sourceLocation: sourceLocation)
}

package func expectEqualBits(_ actual: Float, _ expected: Float, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.bitPattern == expected.bitPattern, sourceLocation: sourceLocation)
}
