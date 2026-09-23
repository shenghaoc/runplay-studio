import Foundation

/// File-backed persistence for the DEM tile settings.
///
/// Layout on disk: `<library-root>/dem-tiles.json`, beside the library
/// manifest. Writes are atomic, and a missing or undecodable file loads as the
/// default settings (no folder), so damaged settings never block the library
/// or an import.
///
/// `@unchecked Sendable` for the same reason as `FileAthleteProfileStore`:
/// `FileManager` is documented thread-safe but not `Sendable`.
public struct FileDEMTileSettingsStore: @unchecked Sendable {
    public enum LoadOutcome: Equatable, Sendable {
        case loaded(DEMTileSettings)
        /// No settings file exists yet.
        case missing
        /// A file exists but could not be decoded; callers fall back to the
        /// default settings and may overwrite the file on the next save.
        case corrupt
    }

    private let settingsURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = rootURL.appendingPathComponent("dem-tiles.json")
        self.fileManager = fileManager
    }

    public func load() -> LoadOutcome {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(DEMTileSettings.self, from: data)
        else {
            return .corrupt
        }
        return .loaded(settings)
    }

    public func loadOrDefault() -> DEMTileSettings {
        if case .loaded(let settings) = load() {
            return settings
        }
        return DEMTileSettings()
    }

    /// Persist the settings atomically, creating the root directory if needed.
    public func save(_ settings: DEMTileSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
