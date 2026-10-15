#if DEBUG
import Foundation
import RunPlayCore
import RunPlayPlatform

// MARK: - Specification

/// The fixed specification of the README demo media.
///
/// Every input that shapes a pixel is set here or verified by
/// `DemoAssetEnvironment`: nothing is read from the user's preferences, a
/// display, or the system appearance. The pipeline's only random values are
/// identifiers (the `UUID`s of route points, segments, and card rows), and
/// none of them reaches a pixel: repeat renders are byte-identical. Swift's
/// per-process `Hasher` seed is the one seed in play, and the environment
/// check requires it to be fixed. If renders ever stop repeating, look first
/// for iteration over a `Set` or `Dictionary` keyed by those identifiers,
/// which no fixed seed makes repeatable.
enum DemoAssetCatalog {
    /// Both appearances are always rendered; neither is resolved from the system.
    static let appearances = PNGSummaryExportAppearance.allCases

    static let summaryCardPrefix = "demo-summary"
    static let routeReplayPrefix = "demo-route-replay"
    static let comparisonReplayPrefix = "demo-comparison-replay"

    /// The production 1920×1080, 30 fps policy the export sheets use.
    static let videoPolicy = WorkoutVideoExportPolicy.production

    /// The shortest preset: 450 frames per replay.
    static let videoDuration = WorkoutVideoDuration.fifteenSeconds

    /// Metrics-only card (exactly 1200×1600). The map-inclusive layout embeds
    /// live Apple Maps imagery, which no pixel check could hold still.
    static func summaryConfiguration(
        _ appearance: PNGSummaryExportAppearance
    ) -> PNGSummaryExportConfiguration {
        PNGSummaryExportConfiguration(
            includeMap: false,
            appearance: appearance,
            routeColorMode: .solid
        )
    }

    /// Relative heart-rate route colouring, so the replay also shows the route
    /// metric palette. The sample's heart rate climbs steadily, while its
    /// timestamps put every split at 5:00, so pace colouring would paint one
    /// flat colour.
    static func routeReplayConfiguration(
        _ appearance: PNGSummaryExportAppearance
    ) -> WorkoutVideoExportConfiguration {
        WorkoutVideoExportConfiguration(
            duration: videoDuration,
            appearance: appearance,
            routeColorMode: .heartRate
        )
    }

    /// Route-Aware alignment, so the replay shows matched clocks.
    static func comparisonReplayConfiguration(
        _ appearance: PNGSummaryExportAppearance
    ) -> ComparisonVideoExportConfiguration {
        ComparisonVideoExportConfiguration(
            duration: videoDuration,
            appearance: appearance,
            alignmentMode: .routeAware
        )
    }

    static func filename(
        _ prefix: String,
        _ appearance: PNGSummaryExportAppearance,
        pathExtension: String
    ) -> String {
        "\(prefix)-\(appearance.rawValue).\(pathExtension)"
    }
}

// MARK: - Environment

/// The process-level inputs the export pipeline reads implicitly.
///
/// The summary card formats its date line with the current locale and time
/// zone, the replay HUD with the current time zone, MapKit labels follow the
/// preferred languages, and Swift seeds `Hasher` per process unless told not
/// to. `scripts/generate-demo-assets.sh` pins all of them; rendering refuses
/// to start otherwise, so a direct launch cannot quietly produce different
/// pixels from the script's.
struct DemoAssetEnvironment {
    static let localeIdentifier = "en_US"
    static let preferredLanguage = "en-US"
    static let deterministicHashingVariable = "SWIFT_DETERMINISTIC_HASHING"

    let locale: Locale
    let preferredLanguages: [String]
    let timeZone: TimeZone
    let variables: [String: String]

    static var current: DemoAssetEnvironment {
        DemoAssetEnvironment(
            locale: .autoupdatingCurrent,
            preferredLanguages: Locale.preferredLanguages,
            timeZone: .autoupdatingCurrent,
            variables: ProcessInfo.processInfo.environment
        )
    }

    /// Every unmet pin, in a fixed order; empty when the process is pinned.
    var problems: [String] {
        var problems: [String] = []
        if locale.identifier != Self.localeIdentifier {
            problems.append(
                "locale is \(locale.identifier), not \(Self.localeIdentifier) (pass -AppleLocale \(Self.localeIdentifier))"
            )
        } else if !formatsDatesLikeFreshLocale {
            problems.append(
                "user date or time format overrides are active; they would change the summary card's date line"
            )
        }
        if preferredLanguages.first != Self.preferredLanguage {
            problems.append(
                "preferred language is \(preferredLanguages.first ?? "unset"), not \(Self.preferredLanguage) (pass -AppleLanguages '(\(Self.preferredLanguage))')"
            )
        }
        if timeZone.secondsFromGMT() != 0 || timeZone.nextDaylightSavingTimeTransition != nil {
            problems.append("time zone is \(timeZone.identifier), not fixed UTC (set TZ=UTC)")
        }
        if variables[Self.deterministicHashingVariable] != "1" {
            problems.append(
                "\(Self.deterministicHashingVariable) is not 1, so Hasher is seeded per process"
            )
        }
        return problems
    }

    /// User overrides such as a forced 24-hour clock travel with the current
    /// locale, never with a freshly constructed one, so formatting one instant
    /// both ways exposes them without hard-coding any OS's format strings.
    private var formatsDatesLikeFreshLocale: Bool {
        let instant = Date(timeIntervalSince1970: 1_783_236_600) // 2026-07-05T07:30:00Z
        return Self.longDateShortTime(locale: locale, timeZone: timeZone).string(from: instant)
            == Self.longDateShortTime(
                locale: Locale(identifier: Self.localeIdentifier),
                timeZone: timeZone
            ).string(from: instant)
    }

    private static func longDateShortTime(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }
}

// MARK: - Errors

enum DemoAssetError: Error, LocalizedError, Equatable {
    case environmentNotPinned([String])
    case missingSampleRun(String)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .environmentNotPinned(let problems):
            return "the process is not pinned for deterministic rendering — run scripts/generate-demo-assets.sh:\n"
                + problems.map { "  - \($0)" }.joined(separator: "\n")
        case .missingSampleRun(let name):
            return "bundled sample run \(name).json is missing from the resource bundle"
        case .unexpectedOutput(let detail):
            return detail
        }
    }
}

// MARK: - Bundled data

/// The two synthetic runs the app bundles for its first-launch demo.
struct DemoAssetSampleRuns: Sendable {
    let primary: RunWorkout
    let comparison: RunWorkout

    /// Loads the same resources, through the same importer, as
    /// `AppState.loadSampleWorkouts`, without creating an `AppState`.
    static func loadBundled(from bundle: Bundle = .module) throws -> DemoAssetSampleRuns {
        DemoAssetSampleRuns(
            primary: try load("sample_run", subdirectory: "Resources", bundle: bundle),
            comparison: try load(
                "comparison_park_run",
                subdirectory: "Resources/fixtures",
                bundle: bundle
            )
        )
    }

    private static func load(
        _ name: String,
        subdirectory: String,
        bundle: Bundle
    ) throws -> RunWorkout {
        guard let url = bundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: subdirectory
        ) else {
            throw DemoAssetError.missingSampleRun(name)
        }
        return try WorkoutImporterFactory.importWorkout(from: url)
    }
}

// MARK: - Generator

/// Renders the README demo media through the production export services:
/// the PNG summary card, Route Replay MP4, and Comparison Replay MP4. It
/// never records the screen or the live replay, and it writes only into
/// `outputDirectory`.
@MainActor
struct DemoAssetGenerator {
    /// Attempts per MapKit basemap before a video fails; map content comes
    /// from Apple's servers, so a transient network error should not fail the
    /// whole run.
    static let mapAttempts = 3

    let runs: DemoAssetSampleRuns
    let outputDirectory: URL
    let log: (String) -> Void

    @discardableResult
    func renderSummaryCards() async throws -> [URL] {
        var written: [URL] = []
        for appearance in DemoAssetCatalog.appearances {
            let result = try await PNGExportService.exportSummaryPNG(
                workout: runs.primary,
                segments: runs.primary.segments,
                configuration: DemoAssetCatalog.summaryConfiguration(appearance)
            )
            let name = DemoAssetCatalog.filename(
                DemoAssetCatalog.summaryCardPrefix,
                appearance,
                pathExtension: "png"
            )
            guard let size = PNGExportRenderer.pngPixelSize(of: result.data),
                  size.width == PNGSummaryExportDimensions.width,
                  size.height == PNGSummaryExportDimensions.height else {
                throw DemoAssetError.unexpectedOutput(
                    "\(name) is not \(PNGSummaryExportDimensions.width)×\(PNGSummaryExportDimensions.height)"
                )
            }
            let url = outputDirectory.appendingPathComponent(name)
            try result.data.write(to: url, options: .atomic)
            log("wrote \(name) (\(size.width)×\(size.height))")
            written.append(url)
        }
        return written
    }

    @discardableResult
    func renderRouteReplays() async throws -> [URL] {
        let exporter = WorkoutVideoExporter()
        let workout = runs.primary
        let context = WorkoutAnalysisContext(workout: workout)
        var written: [URL] = []
        for appearance in DemoAssetCatalog.appearances {
            let configuration = DemoAssetCatalog.routeReplayConfiguration(appearance)
            let name = DemoAssetCatalog.filename(
                DemoAssetCatalog.routeReplayPrefix,
                appearance,
                pathExtension: "mp4"
            )
            let map = try await withMapAttempts(name) {
                try await exporter.prepareMap(
                    workout: workout,
                    configuration: configuration,
                    policy: DemoAssetCatalog.videoPolicy,
                    analysisContext: context
                )
            }
            // The exporter falls back to solid colouring when a metric is
            // missing; the demo must not change silently.
            guard map.effectiveRouteColorMode == configuration.routeColorMode else {
                throw DemoAssetError.unexpectedOutput(
                    "\(name): route colouring fell back to \(map.effectiveRouteColorMode.rawValue)"
                )
            }
            let url = outputDirectory.appendingPathComponent(name)
            let result = try await exporter.export(
                workout: workout,
                configuration: configuration,
                destinationURL: url,
                policy: DemoAssetCatalog.videoPolicy,
                mapPreparation: map,
                analysisContext: context
            )
            try verifyVideo(
                name: name,
                width: result.width,
                height: result.height,
                framesPerSecond: result.framesPerSecond,
                frameCount: result.frameCount
            )
            log(Self.videoSummary(name: name, result.width, result.height, result.frameCount, result.fileSizeBytes))
            written.append(url)
        }
        return written
    }

    @discardableResult
    func renderComparisonReplays() async throws -> [URL] {
        let exporter = ComparisonVideoExporter()
        let pair = ComparisonPair(primary: runs.primary, comparison: runs.comparison)
        let primaryContext = WorkoutAnalysisContext(workout: pair.primary)
        let comparisonContext = WorkoutAnalysisContext(workout: pair.comparison)
        var written: [URL] = []
        for appearance in DemoAssetCatalog.appearances {
            let configuration = DemoAssetCatalog.comparisonReplayConfiguration(appearance)
            let name = DemoAssetCatalog.filename(
                DemoAssetCatalog.comparisonReplayPrefix,
                appearance,
                pathExtension: "mp4"
            )
            let map = try await withMapAttempts(name) {
                try await exporter.prepareMap(
                    pair: pair,
                    configuration: configuration,
                    policy: DemoAssetCatalog.videoPolicy
                )
            }
            let url = outputDirectory.appendingPathComponent(name)
            // Route-Aware unavailability throws rather than degrading to Distance.
            let result = try await exporter.export(
                pair: pair,
                configuration: configuration,
                destinationURL: url,
                policy: DemoAssetCatalog.videoPolicy,
                primaryContext: primaryContext,
                comparisonContext: comparisonContext,
                alignmentSeed: nil,
                mapPreparation: map
            )
            guard result.alignmentMode == configuration.alignmentMode else {
                throw DemoAssetError.unexpectedOutput(
                    "\(name): alignment fell back to \(result.alignmentMode.rawValue)"
                )
            }
            try verifyVideo(
                name: name,
                width: result.width,
                height: result.height,
                framesPerSecond: result.framesPerSecond,
                frameCount: result.frameCount
            )
            log(Self.videoSummary(name: name, result.width, result.height, result.frameCount, result.fileSizeBytes))
            written.append(url)
        }
        return written
    }

    // MARK: Helpers

    private func verifyVideo(
        name: String,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        frameCount: Int
    ) throws {
        let policy = DemoAssetCatalog.videoPolicy
        let expectedFrames = try policy.frameCount(for: DemoAssetCatalog.videoDuration)
        guard width == policy.width,
              height == policy.height,
              framesPerSecond == policy.framesPerSecond,
              frameCount == expectedFrames else {
            throw DemoAssetError.unexpectedOutput(
                "\(name) is \(width)×\(height) at \(framesPerSecond) fps with \(frameCount) frames; "
                    + "expected \(policy.width)×\(policy.height) at \(policy.framesPerSecond) fps with \(expectedFrames)"
            )
        }
    }

    private func withMapAttempts<Value>(
        _ name: String,
        _ prepare: () async throws -> Value
    ) async throws -> Value {
        var attempt = 1
        while true {
            do {
                return try await prepare()
            } catch let error where attempt < Self.mapAttempts && Self.isMapFailure(error) {
                log("\(name): map preparation failed (attempt \(attempt) of \(Self.mapAttempts)): "
                    + "\(error.localizedDescription); retrying")
                try await Task.sleep(for: .seconds(2 * attempt))
                attempt += 1
            }
        }
    }

    private static func isMapFailure(_ error: any Error) -> Bool {
        switch error {
        case WorkoutVideoExportError.mapPreparationFailed,
             ComparisonVideoExportError.mapPreparationFailed:
            return true
        default:
            return false
        }
    }

    private static func videoSummary(
        name: String,
        _ width: Int,
        _ height: Int,
        _ frameCount: Int,
        _ bytes: Int64
    ) -> String {
        let megabytes = Double(bytes) / 1_000_000
        return "wrote \(name) (\(width)×\(height), \(frameCount) frames, "
            + String(format: "%.1f MB)", megabytes)
    }
}
#endif
