import Foundation

/// Central, Swift-owned resource limits for every workout import path.
///
/// These are product limits. Each importer and the shared route processor read
/// them from here so the maximum supported workout size is defined exactly
/// once rather than duplicated per format.
///
/// The C++ engine carries its own `max_route_input_samples` ceiling. That value
/// is an internal safety ceiling sized above `maxRoutePointCount`, not the
/// product limit; see `RouteInterop.hpp`. `WorkoutImportResourceLimitsTests`
/// asserts the engine ceiling keeps at least the documented margin.
public enum WorkoutImportResourceLimits {

    /// Maximum route points in one imported or processed workout.
    ///
    /// Applied per resulting workout — per GPX file, per selected TCX activity,
    /// per decoded JSON route, and per resulting FIT session. Archive entries
    /// inherit the limit through their format importer.
    public static let maxRoutePointCount = 1_000_000

    /// Maximum source payload accepted from one activity file, in bytes.
    ///
    /// Reuses the FIT container ceiling so every format shares one value.
    /// `FITParser.maxFileSize` and `FITMultiSessionImportPolicy.maxContainerBytes`
    /// derive from this constant rather than restating it.
    public static let maxSourceFileBytes = 100 * 1024 * 1024
}

/// A workout was rejected because it exceeds a documented resource limit.
///
/// Resource-limit failures reject the whole workout. RunPlay Studio never
/// truncates or partially imports an oversized route, because a silently
/// shortened workout is worse than a refused one.
public enum WorkoutResourceLimitError: Error, LocalizedError, Sendable, Equatable {

    /// A route exceeded `WorkoutImportResourceLimits.maxRoutePointCount`.
    ///
    /// `count` is the observed count when known. Streaming importers stop at
    /// the first point past the limit and report `limit + 1`, because they
    /// deliberately never build the rest of the route.
    case routePointLimitExceeded(count: Int, limit: Int)

    /// A source payload exceeded `WorkoutImportResourceLimits.maxSourceFileBytes`.
    case sourceFileTooLarge(limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .routePointLimitExceeded(let count, let limit):
            let formattedLimit = Self.formatted(limit)
            if count > limit {
                return "This workout has more than \(formattedLimit) route points, "
                    + "which is the maximum RunPlay Studio supports. "
                    + "It was not imported. Split the recording into shorter "
                    + "workouts and import them separately."
            }
            return "This workout exceeds the \(formattedLimit) route point maximum "
                + "RunPlay Studio supports. It was not imported."
        case .sourceFileTooLarge(let limitBytes):
            let megabytes = limitBytes / (1024 * 1024)
            return "This file is larger than \(megabytes) MB, which is the maximum "
                + "RunPlay Studio reads. It was not imported."
        }
    }

    private static func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

extension WorkoutImportResourceLimits {

    /// Throws when `count` exceeds `maxRoutePointCount`.
    ///
    /// Shared by the importers and the route processor so one comparison
    /// defines the boundary.
    public static func validateRoutePointCount(_ count: Int) throws {
        guard count > maxRoutePointCount else { return }
        throw WorkoutResourceLimitError.routePointLimitExceeded(
            count: count,
            limit: maxRoutePointCount
        )
    }

    /// Throws when in-memory activity bytes exceed `maxSourceFileBytes`.
    public static func validateSourceByteCount(_ count: Int) throws {
        guard count > maxSourceFileBytes else { return }
        throw WorkoutResourceLimitError.sourceFileTooLarge(
            limitBytes: maxSourceFileBytes
        )
    }
}
