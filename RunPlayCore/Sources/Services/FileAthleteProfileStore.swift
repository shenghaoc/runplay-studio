import Foundation

/// File-backed persistence for the local-only athlete profile.
///
/// Layout on disk: `<library-root>/athlete-profile.json`, beside the library
/// manifest. Writes are atomic (`Data.write(to:options:.atomic)`), so a crash
/// mid-write never leaves a half-written profile. A missing or undecodable
/// file loads as the default profile — a corrupt profile must never block
/// the library or the app.
///
/// `@unchecked Sendable` for the same reason as `FileWorkoutLibraryStore`:
/// `FileManager` is documented thread-safe but not `Sendable`.
public struct FileAthleteProfileStore: @unchecked Sendable {
    public enum LoadOutcome: Equatable, Sendable {
        /// A profile file was present and decoded.
        case loaded(AthleteProfile)
        /// No profile file exists yet.
        case missing
        /// A file exists but could not be decoded; callers fall back to the
        /// default profile and may overwrite the file on the next save.
        case corrupt
    }

    private let profileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.profileURL = rootURL.appendingPathComponent("athlete-profile.json")
        self.fileManager = fileManager

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc

        let dec = JSONDecoder()
        self.decoder = dec
    }

    /// Load the profile, distinguishing first run (missing) from a damaged
    /// file (corrupt) so callers can report or repair deliberately.
    public func load() -> LoadOutcome {
        guard fileManager.fileExists(atPath: profileURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: profileURL),
              let profile = try? decoder.decode(AthleteProfile.self, from: data) else {
            return .corrupt
        }
        return .loaded(profile)
    }

    /// Load the profile, falling back to the default for both the missing and
    /// the corrupt case. The convenience callers want when a damaged file
    /// should simply behave like an unconfigured app.
    public func loadOrDefault() -> AthleteProfile {
        switch load() {
        case .loaded(let profile): return profile
        case .missing, .corrupt: return AthleteProfile()
        }
    }

    /// Persist the profile atomically, creating the root directory if needed.
    public func save(_ profile: AthleteProfile) throws {
        let data = try encoder.encode(profile)
        try fileManager.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: profileURL, options: .atomic)
    }
}
