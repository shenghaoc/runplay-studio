import Foundation

/// Protocol for workout file importers.
public protocol WorkoutImporting: Sendable {
    /// The file formats this importer supports.
    var supportedExtensions: [String] { get }

    /// Import a workout from a file URL.
    func importWorkout(from url: URL) throws -> RunWorkout

    /// Import a workout from in-memory activity bytes.
    ///
    /// Default implementation loads nothing from disk. Concrete importers
    /// should parse `input.data` with the same logic as the URL path.
    func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout
}

extension WorkoutImporting {
    public func importWorkout(from input: WorkoutImportInput) throws -> RunWorkout {
        throw WorkoutImportError.unsupportedFormat(input.fileExtension)
    }
}

extension WorkoutImporting {
    /// Validates that a URL is a local file URL and that the file exists.
    /// Call at the top of `importWorkout(from:)` to enforce SSRF prevention.
    public func validateLocalFile(_ url: URL) throws {
        guard url.isFileURL else {
            throw WorkoutImportError.invalidFormat("Only local file URLs are supported")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkoutImportError.fileNotFound(url)
        }
    }

    /// Reads a local activity file, consuming at most
    /// `WorkoutImportResourceLimits.maxSourceFileBytes + 1` bytes.
    ///
    /// Use this instead of `Data(contentsOf:)`. Reading one byte past the limit
    /// is what proves the file is oversized, and stopping there means a
    /// malformed or hostile file cannot exhaust memory before the size check
    /// runs. Declared file metadata is never trusted in place of the read.
    public func readBoundedSourceData(
        at url: URL,
        limit: Int = WorkoutImportResourceLimits.maxSourceFileBytes
    ) throws -> Data {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WorkoutImportError.fileNotFound(url)
        }
        defer { try? handle.close() }

        let chunkSize = 1 << 20
        var data = Data()
        data.reserveCapacity(min(limit + 1, chunkSize))

        while data.count <= limit {
            let remaining = limit + 1 - data.count
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: min(remaining, chunkSize))
            } catch {
                throw WorkoutImportError.parsingError(
                    "This file could not be read: \(error.localizedDescription)"
                )
            }
            guard let chunk, !chunk.isEmpty else { break }
            data.append(chunk)
        }

        guard data.count <= limit else {
            throw WorkoutResourceLimitError.sourceFileTooLarge(
                limitBytes: WorkoutImportResourceLimits.maxSourceFileBytes
            )
        }
        return data
    }
}

/// Errors that can occur during workout import.
public enum WorkoutImportError: Error, LocalizedError, Sendable {
    case fileNotFound(URL)
    case invalidFormat(String)
    case parsingError(String)
    case missingData(String)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .invalidFormat(let detail):
            return "Invalid file format: \(detail)"
        case .parsingError(let detail):
            return "Import error: \(detail)"
        case .missingData(let detail):
            return "Missing data: \(detail)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: .\(ext)"
        }
    }
}
