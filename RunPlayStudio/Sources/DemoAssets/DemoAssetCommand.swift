#if DEBUG
import Foundation

/// What a `--demo-assets` launch asks for.
enum DemoAssetInvocation: Equatable {
    case render(outputDirectory: URL, selection: DemoAssetSelection)
    case compare(reference: URL, candidate: URL, diffOutput: URL?)
}

/// Which media `render` produces.
enum DemoAssetSelection: String, CaseIterable, Sendable {
    case all
    case summary
    case videos
}

/// Parses the headless `--demo-assets` launch arguments.
///
/// Single-dash pairs such as `-AppleLocale en_US` belong to the user-defaults
/// argument domain, which Foundation reads by itself; they are skipped
/// wherever they appear.
enum DemoAssetCommandLine {
    static let flag = "--demo-assets"

    static let usage = """
    usage (debug builds; scripts/generate-demo-assets.sh is the supported entry point):
      RunPlayStudio --demo-assets render --output-dir <dir> [--only all|summary|videos]
      RunPlayStudio --demo-assets compare --reference <png> --candidate <png> [--diff-output <png>]
    """

    struct ParseError: Error, LocalizedError, Equatable {
        let message: String

        var errorDescription: String? { message }
    }

    static func isRequested(by arguments: [String]) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    static func parse(_ arguments: [String]) throws -> DemoAssetInvocation {
        var tokens = commandTokens(arguments)
        guard tokens.first == flag else {
            throw ParseError(message: "\(flag) must come first")
        }
        tokens.removeFirst()
        guard let subcommand = tokens.first else {
            throw ParseError(message: "missing subcommand")
        }
        let options = try parseOptions(Array(tokens.dropFirst()))

        switch subcommand {
        case "render":
            try options.requireOnly(["--output-dir", "--only"])
            let selection: DemoAssetSelection
            if let raw = options.values["--only"] {
                guard let parsed = DemoAssetSelection(rawValue: raw) else {
                    throw ParseError(message: "unknown --only value \(raw)")
                }
                selection = parsed
            } else {
                selection = .all
            }
            return .render(
                outputDirectory: try options.url("--output-dir", isDirectory: true),
                selection: selection
            )
        case "compare":
            try options.requireOnly(["--reference", "--candidate", "--diff-output"])
            return .compare(
                reference: try options.url("--reference"),
                candidate: try options.url("--candidate"),
                diffOutput: options.values["--diff-output"].map { URL(fileURLWithPath: $0) }
            )
        default:
            throw ParseError(message: "unknown subcommand \(subcommand)")
        }
    }

    /// Arguments after the executable path, without user-defaults pairs.
    private static func commandTokens(_ arguments: [String]) -> [String] {
        var tokens: [String] = []
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let token = arguments[index]
            if token.count > 1, token.hasPrefix("-"), !token.hasPrefix("--") {
                index += 2
            } else {
                tokens.append(token)
                index += 1
            }
        }
        return tokens
    }

    private struct Options {
        var values: [String: String] = [:]

        func requireOnly(_ allowed: Set<String>) throws {
            if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
                throw ParseError(message: "unknown option \(unknown)")
            }
        }

        func url(_ option: String, isDirectory: Bool = false) throws -> URL {
            guard let path = values[option] else {
                throw ParseError(message: "missing \(option)")
            }
            return URL(fileURLWithPath: path, isDirectory: isDirectory)
        }
    }

    private static func parseOptions(_ tokens: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < tokens.count {
            let option = tokens[index]
            guard option.hasPrefix("--") else {
                throw ParseError(message: "unexpected argument \(option)")
            }
            guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
                throw ParseError(message: "\(option) needs a value")
            }
            guard options.values[option] == nil else {
                throw ParseError(message: "\(option) given twice")
            }
            options.values[option] = tokens[index + 1]
            index += 2
        }
        return options
    }
}

/// Runs a `--demo-assets` launch to completion and exits the process.
@MainActor
enum DemoAssetCommand {
    /// Process exit codes the script interprets.
    enum ExitStatus: Int32 {
        case success = 0
        /// `compare` found a difference beyond the tolerance.
        case imagesDiffer = 1
        case failure = 2
        case usage = 64
    }

    static func runAndExit(arguments: [String]) -> Never {
        let invocation: DemoAssetInvocation
        do {
            invocation = try DemoAssetCommandLine.parse(arguments)
        } catch {
            printError("demo-assets: \(error.localizedDescription)\n\(DemoAssetCommandLine.usage)")
            exit(ExitStatus.usage.rawValue)
        }

        Task { @MainActor in
            let status = await run(invocation)
            exit(status.rawValue)
        }
        // Main-actor jobs and framework callbacks need the main run loop; the
        // port keeps it from returning while every job is suspended.
        RunLoop.main.add(NSMachPort(), forMode: .default)
        RunLoop.main.run()
        exit(ExitStatus.failure.rawValue)
    }

    static func run(_ invocation: DemoAssetInvocation) async -> ExitStatus {
        do {
            switch invocation {
            case .render(let outputDirectory, let selection):
                try await render(into: outputDirectory, selection: selection)
                return .success
            case .compare(let reference, let candidate, let diffOutput):
                return try compare(reference: reference, candidate: candidate, diffOutput: diffOutput)
            }
        } catch {
            printError("demo-assets: \(error.localizedDescription)")
            return .failure
        }
    }

    private static func render(into directory: URL, selection: DemoAssetSelection) async throws {
        let problems = DemoAssetEnvironment.current.problems
        guard problems.isEmpty else {
            throw DemoAssetError.environmentNotPinned(problems)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let generator = DemoAssetGenerator(
            runs: try DemoAssetSampleRuns.loadBundled(),
            outputDirectory: directory,
            log: { printError("demo-assets: \($0)") }
        )
        if selection != .videos {
            try await generator.renderSummaryCards()
        }
        if selection != .summary {
            try await generator.renderRouteReplays()
            try await generator.renderComparisonReplays()
        }
    }

    private static func compare(
        reference referenceURL: URL,
        candidate candidateURL: URL,
        diffOutput: URL?
    ) throws -> ExitStatus {
        let tolerance = DemoAssetPixelTolerance.summaryCard
        let reference = try DemoAssetImageComparator.loadImage(at: referenceURL)
        let candidate = try DemoAssetImageComparator.loadImage(at: candidateURL)
        let difference = try DemoAssetImageComparator.compare(
            reference: reference,
            candidate: candidate,
            tolerance: tolerance
        )
        let name = candidateURL.lastPathComponent
        printError("demo-assets: \(name): \(difference.report(tolerance: tolerance))")
        guard difference.isWithin(tolerance) else {
            if let diffOutput, difference.sizesMatch {
                let image = try DemoAssetImageComparator.diffImage(
                    reference: reference,
                    candidate: candidate,
                    tolerance: tolerance
                )
                try PNGExportRenderer.encodePNG(cgImage: image).write(to: diffOutput, options: .atomic)
                printError("demo-assets: \(name): changed pixels drawn in magenta at \(diffOutput.path)")
            }
            return .imagesDiffer
        }
        return .success
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
#endif
