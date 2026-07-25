import Foundation

/// How one FIT session's sport maps onto RunPlay Studio's running-only product.
public enum FITSessionSportClassification: String, Codable, Hashable, Sendable, CaseIterable {
    /// FIT profile `running`.
    case running
    /// Sport field missing, or a raw value outside the known profile enum.
    /// Treated as running, but the session carries an explicit warning.
    case unknownTreatedAsRunning
    /// A known profile sport that this product does not analyse.
    case unsupported

    public var isImportable: Bool {
        switch self {
        case .running, .unknownTreatedAsRunning: return true
        case .unsupported: return false
        }
    }
}

/// Single source of truth for FIT sport handling.
///
/// The scanner and the importer both call this. Duplicating the policy is what
/// previously allowed a session to be listed as importable in one place and
/// rejected in another.
///
/// Policy (unchanged from the pre-existing single-session FIT importer):
/// `FITSport.running` is supported; a missing or unrecognised sport falls back
/// to running with a warning; every other known profile sport — **including
/// walking and hiking** — is unsupported. This deliberately differs from
/// `StravaActivityTypePolicy`, whose walk/hike acceptance applies to Strava
/// bulk-export metadata rows rather than to FIT session messages.
public enum FITSportPolicy {

    public static func classify(sport rawSport: UInt8?) -> FITSessionSportClassification {
        guard let rawSport else { return .unknownTreatedAsRunning }
        guard let sport = FITSport(rawValue: rawSport) else { return .unknownTreatedAsRunning }
        return sport.isRunning ? .running : .unsupported
    }

    public static func classify(session: FITSessionMessage) -> FITSessionSportClassification {
        classify(sport: session.sport)
    }

    /// Human-readable sport name for the review sheet. Never exposes raw
    /// numeric profile internals for values the profile enum recognises.
    public static func displayName(sport rawSport: UInt8?) -> String {
        guard let rawSport else { return "Unspecified" }
        guard let sport = FITSport(rawValue: rawSport) else { return "Unrecognised" }
        return displayName(sport)
    }

    /// Sub-sport is surfaced only when the profile value is meaningful; the
    /// full sub-sport enum is not modelled, so unknown values stay hidden
    /// rather than leaking a bare number into the UI.
    public static func subSportDescription(subSport rawSubSport: UInt8?) -> String? {
        guard let rawSubSport, rawSubSport != FITParser.invalidUint8, rawSubSport != 0 else {
            return nil
        }
        switch rawSubSport {
        case 1: return "Treadmill"
        case 2: return "Street"
        case 3: return "Trail"
        case 4: return "Track"
        case 6: return "Indoor"
        case 17: return "Virtual"
        default: return nil
        }
    }

    /// Activity type string stored on `WorkoutMetadata`.
    public static func activityType(sport rawSport: UInt8?) -> String {
        guard let rawSport, let sport = FITSport(rawValue: rawSport) else { return "running" }
        switch sport {
        case .running: return "running"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .generic, .training: return "running"
        default: return "running"
        }
    }

    private static func displayName(_ sport: FITSport) -> String {
        switch sport {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .generic: return "Generic"
        case .training: return "Training"
        case .transition: return "Transition"
        case .multisport: return "Multisport"
        case .rowing: return "Rowing"
        case .fitnessEquipment: return "Fitness equipment"
        case .crossCountrySkiing: return "Cross-country skiing"
        case .alpineSkiing: return "Alpine skiing"
        case .snowboarding: return "Snowboarding"
        case .paddling: return "Paddling"
        case .inlineSkating: return "Inline skating"
        case .rockClimbing: return "Rock climbing"
        case .hiit: return "HIIT"
        default:
            // Profile-known but not individually named: use the case name.
            return String(describing: sport)
        }
    }
}
