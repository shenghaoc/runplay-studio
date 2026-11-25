/// An FNV-1a-64 digest of a value's complete reflected description.
///
/// `String(reflecting:)` prints every stored property, and it prints each
/// `Double` as the shortest decimal that round-trips to the same bits, so two
/// values get the same digest only when every field is exactly equal. Tests use
/// it to pin a whole output value that is too large to spell out field by
/// field.
enum ExactValueDigest {
    static func of(_ value: some Any) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in String(reflecting: value).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
        }
        return hash
    }

    static func hex(_ digest: UInt64) -> String {
        let digits = String(digest, radix: 16)
        return "0x" + String(repeating: "0", count: 16 - digits.count) + digits
    }
}
