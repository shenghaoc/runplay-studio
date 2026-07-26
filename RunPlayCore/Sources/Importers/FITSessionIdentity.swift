import Foundation

/// Builds stable, content-derived identities for FIT sessions.
///
/// Requirements this encoding satisfies:
/// - The same container always yields the same session IDs.
/// - Renaming the file does not change any ID (no path or filename input).
/// - Sibling sessions differ (source ordinal is part of the tuple).
/// - Identical session metadata in two containers cannot collide (the whole
///   container hash is part of the tuple).
/// - No locale-formatted dates, absolute paths, or account identifiers.
///
/// Session `message_index` is intentionally **not** part of the tuple: the FIT
/// decoder does not yet parse that field on session messages. Adding it later
/// requires bumping ``version`` so existing libraries re-import cleanly rather
/// than silently changing IDs.
public enum FITSessionIdentity {

    /// Version prefix. Bump only when the identity tuple changes shape;
    /// existing libraries then treat re-imports as new workouts rather than
    /// silently merging them.
    public static let version = "fit-session-v1"

    /// ASCII unit separator. Fixed, locale-independent, and impossible in the
    /// integer components below.
    private static let separator = "\u{001F}"

    /// Build the provider activity ID for one session.
    ///
    /// - Parameters:
    ///   - containerSHA256: Lowercase hex SHA-256 of the whole original file.
    ///   - sourceIndex: Zero-based FIT source ordinal.
    ///   - session: The session message.
    ///   - digest: Injected SHA-256 provider.
    public static func providerActivityID(
        containerSHA256: String,
        sourceIndex: Int,
        session: FITSessionMessage,
        digest: any ContentDigesting
    ) -> String {
        let components: [String] = [
            version,
            containerSHA256.lowercased(),
            String(sourceIndex),
            component(FITParser.timestampIfValid(session.startTime)),
            component(FITParser.timestampIfValid(session.timestamp)),
            component(session.sport),
            component(session.subSport),
            component(session.firstLapIndex.flatMap { $0 == FITParser.invalidUint16 ? nil : $0 }),
            component(session.numberOfLaps.flatMap { $0 == FITParser.invalidUint16 ? nil : $0 })
        ]
        let tuple = components.joined(separator: separator)
        return "\(version):\(digest.sha256Hex(ofUTF8: tuple))"
    }

    /// Encode an optional integer without locale formatting. A missing value is
    /// distinct from any present value, so an absent `sub_sport` and a
    /// `sub_sport` of zero never produce the same identity.
    private static func component<Value: BinaryInteger>(_ value: Value?) -> String {
        guard let value else { return "-" }
        return String(value)
    }
}
