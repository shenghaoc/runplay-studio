import Foundation
import CryptoKit
import RunPlayCore

/// SHA-256 content fingerprinting using Apple CryptoKit.
///
/// Digests are lowercase hexadecimal. Do not implement a custom hash.
public enum ContentHasher {
    /// ASCII nibble table for lowercase hex (`0-9a-f`). Static so every digest
    /// shares one 16-byte table instead of rebuilding character storage.
    private static let hexDigits = Array("0123456789abcdef".utf8)

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        // ⚡ Bolt: Write both nibbles into one UTF-8 buffer — no intermediate
        // [String] from map/joined, no per-byte String(format:), no Character appends.
        // SHA-256 is always `SHA256.byteCount` bytes → fixed 2× hex length.
        let hexLength = SHA256.byteCount * 2
        return String(unsafeUninitializedCapacity: hexLength) { buffer in
            var i = 0
            for byte in digest {
                buffer[i] = hexDigits[Int(byte >> 4)]
                buffer[i &+ 1] = hexDigits[Int(byte & 0x0F)]
                i &+= 2
            }
            return i
        }
    }
}

/// Injects CryptoKit hashing into cross-platform core services.
///
/// `RunPlayCore` builds on Linux, where CryptoKit does not exist, so it depends
/// on `ContentDigesting` rather than importing a hash implementation. This is
/// the only FIT-adjacent type the platform layer owns: FIT parsing, session
/// attribution, and workout construction all stay in core.
public struct CryptoKitContentDigest: ContentDigesting {
    public init() {}

    public func sha256Hex(of data: Data) -> String {
        ContentHasher.sha256Hex(of: data)
    }
}
