import Foundation
import CryptoKit
import RunPlayCore

/// SHA-256 content fingerprinting using Apple CryptoKit.
///
/// Digests are lowercase hexadecimal. Do not implement a custom hash.
public enum ContentHasher {
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
