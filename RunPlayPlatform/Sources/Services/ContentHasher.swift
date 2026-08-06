import Foundation
import CryptoKit
import RunPlayCore

/// SHA-256 content fingerprinting using Apple CryptoKit.
///
/// Digests are lowercase hexadecimal. Do not implement a custom hash.
public enum ContentHasher {
    // ⚡ Bolt: Cache hex characters to avoid string allocation per byte
    private static let hexChars = Array("0123456789abcdef")

    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        // ⚡ Bolt: Inline loop avoids intermediate [String] array allocation from .map { ... }.joined()
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(hexChars[Int(byte >> 4)])
            hex.append(hexChars[Int(byte & 0x0F)])
        }
        return hex
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
