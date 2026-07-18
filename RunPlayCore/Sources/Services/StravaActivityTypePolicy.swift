import Foundation

/// Conservative sport/activity-type policy for Strava bulk exports.
///
/// RunPlay Studio is a running-analysis product. Only running-oriented types
/// (and walk/hike only when existing importers would accept GPS routes for them)
/// are selected by default. Individual importers remain authoritative for
/// route validation.
public enum StravaActivityTypePolicy {

    public enum Classification: Equatable, Sendable {
        case running
        case walkOrHike
        case unsupported
        case unknown
    }

    /// Normalize a free-form activity type string for comparison.
    public static func normalize(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    public static func classify(_ raw: String?) -> Classification {
        let type = normalize(raw)
        guard !type.isEmpty else { return .unknown }

        // Running family (Strava sport/activity types and common aliases).
        let running: Set<String> = [
            "run", "running", "trail run", "trailrun", "trail running",
            "virtual run", "virtualrun", "virtual running",
            "treadmill", "treadmill run", "treadmillrun",
            "track", "track run", "trackrun",
            "race", "road run", "roadrun",
        ]
        if running.contains(type) {
            return .running
        }

        // Walk / hike — accepted only when a GPS route exists (importer enforces).
        let walkHike: Set<String> = [
            "walk", "walking", "hike", "hiking",
        ]
        if walkHike.contains(type) {
            return .walkOrHike
        }

        // Explicit non-running sports. Generic "workout" stays unknown.
        let unsupported: Set<String> = [
            "ride", "cycling", "bike", "virtual ride", "ebikeride", "e bike ride",
            "mountain bike ride", "gravel ride", "handcycle",
            "swim", "swimming", "open water swim",
            "ski", "alpine ski", "backcountry ski", "nordic ski", "snowboard",
            "row", "rowing", "kayaking", "canoeing", "stand up paddling",
            "weight training", "yoga", "crossfit",
            "soccer", "tennis", "golf", "elliptical", "stair stepper",
            "ice skate", "inline skate", "skateboard", "surf", "sail",
            "rock climbing", "wheelchair",
        ]
        if unsupported.contains(type) {
            return .unsupported
        }

        // Strava sometimes uses SportType casing; strip spaces already done.
        if type.hasSuffix("run") || type.hasPrefix("run ") {
            return .running
        }

        return .unknown
    }

    /// Whether candidates of this type should be selected by default.
    public static func isSelectedByDefault(_ raw: String?) -> Bool {
        switch classify(raw) {
        case .running, .walkOrHike:
            return true
        case .unsupported, .unknown:
            return false
        }
    }
}
