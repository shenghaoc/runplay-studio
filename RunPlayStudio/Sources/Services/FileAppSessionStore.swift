import Foundation

protocol AppSessionStoring: Sendable {
    func load() async -> AppSessionSnapshot?
    func save(_ snapshot: AppSessionSnapshot) async throws
    func clear() async throws
}

enum FileAppSessionStoreError: Error, Equatable, Sendable {
    case tooLarge(limit: Int)
    case encodingFailed
}

/// Actor-backed local session store. All filesystem work happens off the
/// main actor, and every successful save replaces the prior JSON atomically.
actor FileAppSessionStore: AppSessionStoring {
    let rootURL: URL
    let sessionURL: URL
    private let maxFileBytes: Int
    private let fileManager: FileManager

    init(
        rootURL: URL,
        maxFileBytes: Int = AppSessionPolicy.maxFileBytes,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.sessionURL = rootURL.appendingPathComponent("session.json", isDirectory: false)
        self.maxFileBytes = max(1, maxFileBytes)
        self.fileManager = fileManager
    }

    func load() async -> AppSessionSnapshot? {
        guard fileManager.fileExists(atPath: sessionURL.path) else { return nil }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: sessionURL.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= maxFileBytes else {
                return nil
            }
            let data = try Data(contentsOf: sessionURL, options: [.mappedIfSafe])
            guard data.count <= maxFileBytes else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AppSessionSnapshot.self, from: data)
        } catch {
            // Corrupt, malformed, future-version, and unreadable files all
            // share the same safe startup fallback.
            return nil
        }
    }

    func save(_ snapshot: AppSessionSnapshot) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            throw FileAppSessionStoreError.encodingFailed
        }
        guard data.count <= maxFileBytes else {
            throw FileAppSessionStoreError.tooLarge(limit: maxFileBytes)
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let temporaryURL = rootURL.appendingPathComponent(
            ".session-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            if fileManager.fileExists(atPath: sessionURL.path) {
                _ = try fileManager.replaceItemAt(sessionURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: sessionURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    func clear() async throws {
        guard fileManager.fileExists(atPath: sessionURL.path) else { return }
        try fileManager.removeItem(at: sessionURL)
    }
}
