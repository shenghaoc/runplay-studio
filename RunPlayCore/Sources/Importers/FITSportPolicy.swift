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
        guard let rawSport else { return coreLocalized("Unspecified") }
        guard let sport = FITSport(rawValue: rawSport) else { return coreLocalized("Unrecognised") }
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
        case 1: return coreLocalized("Treadmill")
        case 2: return coreLocalized("Street")
        case 3: return coreLocalized("Trail")
        case 4: return coreLocalized("Track")
        case 6: return coreLocalized("Indoor")
        case 17: return coreLocalized("Virtual")
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
        case .running: return coreLocalized("Running")
        case .cycling: return coreLocalized("Cycling")
        case .swimming: return coreLocalized("Swimming")
        case .walking: return coreLocalized("Walking")
        case .hiking: return coreLocalized("Hiking")
        case .generic: return coreLocalized("Generic")
        case .training: return coreLocalized("Training")
        case .transition: return coreLocalized("Transition")
        case .multisport: return coreLocalized("Multisport")
        case .rowing: return coreLocalized("Rowing")
        case .fitnessEquipment: return coreLocalized("Fitness equipment")
        case .crossCountrySkiing: return coreLocalized("Cross-country skiing")
        case .alpineSkiing: return coreLocalized("Alpine skiing")
        case .snowboarding: return coreLocalized("Snowboarding")
        case .paddling: return coreLocalized("Paddling")
        case .inlineSkating: return coreLocalized("Inline skating")
        case .rockClimbing: return coreLocalized("Rock climbing")
        case .hiit: return coreLocalized("HIIT")
        case .basketball: return coreLocalized("Basketball")
        case .soccer: return coreLocalized("Soccer")
        case .tennis: return coreLocalized("Tennis")
        case .americanFootball: return coreLocalized("American football")
        case .mountaineering: return coreLocalized("Mountaineering")
        case .flying: return coreLocalized("Flying")
        case .eBiking: return coreLocalized("E-biking")
        case .motorcycling: return coreLocalized("Motorcycling")
        case .boating: return coreLocalized("Boating")
        case .driving: return coreLocalized("Driving")
        case .golf: return coreLocalized("Golf")
        case .hangGliding: return coreLocalized("Hang gliding")
        case .horsebackRiding: return coreLocalized("Horseback riding")
        case .hunting: return coreLocalized("Hunting")
        case .fishing: return coreLocalized("Fishing")
        case .sailing: return coreLocalized("Sailing")
        case .iceSkating: return coreLocalized("Ice skating")
        case .skyDiving: return coreLocalized("Skydiving")
        case .snowshoeing: return coreLocalized("Snowshoeing")
        case .snowmobiling: return coreLocalized("Snowmobiling")
        case .standUpPaddleboarding: return coreLocalized("Stand-up paddleboarding")
        case .surfing: return coreLocalized("Surfing")
        case .wakeboarding: return coreLocalized("Wakeboarding")
        case .waterSkiing: return coreLocalized("Water skiing")
        case .kayaking: return coreLocalized("Kayaking")
        case .rafting: return coreLocalized("Rafting")
        case .windsurfing: return coreLocalized("Windsurfing")
        case .kitesurfing: return coreLocalized("Kitesurfing")
        case .tactical: return coreLocalized("Tactical")
        case .jumpmaster: return coreLocalized("Jumpmaster")
        case .boxing: return coreLocalized("Boxing")
        case .floorClimbing: return coreLocalized("Floor climbing")
        case .baseball: return coreLocalized("Baseball")
        case .diving: return coreLocalized("Diving")
        case .racket: return coreLocalized("Racket sports")
        case .waterTubing: return coreLocalized("Water tubing")
        case .wakesurfing: return coreLocalized("Wakesurfing")
        case .all: return coreLocalized("All sports")
        }
    }
}
