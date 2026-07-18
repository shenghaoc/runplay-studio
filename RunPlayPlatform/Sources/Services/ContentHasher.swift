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
