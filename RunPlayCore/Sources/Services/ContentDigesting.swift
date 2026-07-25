import Foundation

/// Supplies SHA-256 content fingerprints to cross-platform core code.
///
/// `RunPlayCore` must build on Linux with Foundation only, so it cannot import
/// CryptoKit, and the repository forbids hand-rolled hash implementations.
/// Platform layers inject a conformance instead (see `CryptoKitContentDigest`).
///
/// Implementations must return lowercase hexadecimal and must be deterministic
/// for identical input: persisted provenance identity depends on it.
public protocol ContentDigesting: Sendable {
    func sha256Hex(of data: Data) -> String
}

extension ContentDigesting {
    /// Digest a UTF-8 string. Callers build identity tuples from integers and
    /// enum raw values only — never locale-formatted text or file paths.
    public func sha256Hex(ofUTF8 string: String) -> String {
        sha256Hex(of: Data(string.utf8))
    }
}
