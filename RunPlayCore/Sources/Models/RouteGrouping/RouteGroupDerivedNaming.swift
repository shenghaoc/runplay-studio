import Foundation

/// Collision-aware derived display names for unnamed route groups.
///
/// `defaultDisplayName(distanceMeters:closesLoop:)` names one group from its
/// own geometry alone, so two unrelated routes with the same rounded
/// distance and the same closure produce byte-identical names ("1.2 km
/// Loop") — and `%.1f km` rounding widens the collision, since 1.16 km and
/// 1.24 km both render as 1.2 km. This extension derives names for a *set*
/// of groups at once so colliding siblings can disambiguate one another,
/// using only facts already persisted in `WorkoutRouteGroupSummary`: no
/// geocoding, no network, no new storage (the privacy model forbids the
/// first two).
extension WorkoutRouteGroup {
    /// Start-to-finish distance under which a representative counts as a
    /// loop for a derived name. The single product copy of the number; the
    /// surfaces that used to hold their own constant read this one.
    public static let defaultLoopClosureDistanceMeters: Double = 100

    /// Derives a display name for every group in `groups`, aware of name
    /// collisions between the derived ones. Distance always comes from
    /// `representativeSummary.facts.totalDistanceMeters` — the persisted
    /// snapshot every holder of a group already has — so every caller
    /// (routes list, library filter menu, heatmap picker) derives the same
    /// name from the same group without loading representative snapshots.
    ///
    /// Rules, applied in order:
    ///
    /// 1. A group with a non-empty user-assigned `name` is returned
    ///    verbatim: never suffixed, and never consulted when disambiguating
    ///    others. Two identically user-named groups stay identical — that is
    ///    the user's choice, not a collision to repair.
    /// 2. A group with no `representativeSummary` keeps today's plain
    ///    fallback name ("Route"): no facts can be read, so it carries no
    ///    token.
    /// 3. Every other group's base name is exactly
    ///    `defaultDisplayName(distanceMeters:closesLoop:)` over its
    ///    persisted facts — loop closure from the persisted start/finish
    ///    pair measured with `GeoDistance` against
    ///    `loopClosureDistanceMeters`.
    /// 4. A base name held by only one group is emitted unchanged. A base
    ///    name held by several is disambiguated with an eight-point compass
    ///    token: the bearing from the representative's start point to the
    ///    centre of its bounding box (see `compassToken(for:)` for why not
    ///    start-to-finish). The token is stable across imports — it does
    ///    not depend on run count or dates, which change as a group gains
    ///    members, only on geometry the user learns to recognise.
    /// 5. Terminal fallback: within one base name, repeated tokens (or
    ///    repeated fallback names) are separated by a numeric ordinal in
    ///    parentheses — "1.2 km Loop (NE 2)", "Route (2)" — so no two
    ///    derived names are ever identical.
    ///
    /// The result is a pure function of the input *set*: before any suffix
    /// or ordinal is assigned, the derived groups are ordered by
    /// representative start date (earlier first, missing last — the
    /// longest-known route keeps the cleanest name) with the group id as
    /// the final tiebreak, so input order never decides anything and the
    /// same set always yields the same names. Adding a group that does not
    /// collide leaves every existing name untouched; adding one that does
    /// legitimately shifts the bare name to a tokened one, which is the
    /// disambiguation working.
    public static func derivedDisplayNames(
        for groups: [WorkoutRouteGroup],
        loopClosureDistanceMeters: Double
    ) -> [UUID: String] {
        var names: [UUID: String] = [:]
        names.reserveCapacity(groups.count)

        struct Derived: Hashable {
            let groupID: UUID
            let startDate: Date?
            let baseName: String
            let token: String?
        }
        var derived: [Derived] = []
        derived.reserveCapacity(groups.count)

        for group in groups {
            if let name = group.name, !name.isEmpty {
                names[group.id] = name
                continue
            }
            guard let summary = group.representativeSummary else {
                derived.append(Derived(
                    groupID: group.id,
                    startDate: nil,
                    baseName: unnamedFallbackName,
                    token: nil
                ))
                continue
            }
            let facts = summary.facts
            let closesLoop = GeoDistance.distanceMeters(
                fromLat: facts.startLatitude,
                lon: facts.startLongitude,
                toLat: facts.finishLatitude,
                lon: facts.finishLongitude
            ) <= loopClosureDistanceMeters
            derived.append(Derived(
                groupID: group.id,
                startDate: summary.startDate,
                baseName: defaultDisplayName(
                    distanceMeters: facts.totalDistanceMeters,
                    closesLoop: closesLoop
                ),
                token: compassToken(for: facts)
            ))
        }

        // Deterministic ordinal assignment: never let input order or
        // dictionary iteration decide who keeps the cleaner name. Earlier
        // representative start date first (missing dates last), then the
        // group id's canonical string as the total-order tiebreak.
        derived.sort { lhs, rhs in
            switch (lhs.startDate, rhs.startDate) {
            case (let left?, let right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.groupID.uuidString < rhs.groupID.uuidString
            }
        }

        // Clusters by base name; members arrive in the sorted order above,
        // so first-seen counts and ordinals are reproducible.
        var clusters: [String: [Derived]] = [:]
        clusters.reserveCapacity(derived.count)
        for candidate in derived {
            clusters[candidate.baseName, default: []].append(candidate)
        }

        for (baseName, cluster) in clusters {
            guard cluster.count > 1 else {
                names[cluster[0].groupID] = baseName
                continue
            }
            var occurrences: [String: Int] = [:]
            for candidate in cluster {
                // Fallback candidates have no token; they keep the bare
                // fallback unless another fallback shares it, in which case
                // the ordinal alone ("Route (2)") separates them.
                let key = candidate.token ?? ""
                occurrences[key, default: 0] += 1
                let occurrence = occurrences[key] ?? 0
                guard let token = candidate.token else {
                    names[candidate.groupID] = occurrence == 1
                        ? baseName
                        : baseName + disambiguatedSuffix(String(occurrence))
                    continue
                }
                names[candidate.groupID] = baseName + disambiguatedSuffix(
                    occurrence == 1 ? token : "\(token) \(occurrence)"
                )
            }
        }

        return names
    }

    /// Today's plain fallback for a group whose representative summary is
    /// missing (English default; same key and text the routes list uses).
    private static var unnamedFallbackName: String {
        #if canImport(Darwin)
        String(localized: "route_group.unnamed", defaultValue: "Route")
        #else
        "Route"
        #endif
    }

    /// Eight-point compass token for one route's facts.
    ///
    /// The bearing runs from the representative's start point to the centre
    /// of the route's bounding box — deliberately not start-to-finish. A
    /// loop starts and finishes at (nearly) the same point, so a
    /// start-to-finish bearing is numerical noise for exactly the routes
    /// that most often collide on "N km Loop"; the extent centre is a
    /// property of the whole route, so the same start corner with a route
    /// extending north yields "N" while one extending east yields "E". For
    /// point-to-point routes the same vector reads as the direction headed
    /// overall. Ordinary GPS jitter moves the centre by metres while the
    /// sectors are 45° wide, so the token is stable across repeats. The
    /// degenerate case — a start that already sits at its extent centre —
    /// resolves to `atan2(0, 0)` (north) and stays deterministic; any
    /// residual collision is settled by the numeric terminal fallback.
    ///
    /// Computed through `GeoDistance.latLonToMeters`, the one shared local
    /// metre projection, so no second distance implementation exists here.
    private static func compassToken(for facts: RouteGroupingRouteFacts) -> String {
        let centreLatitude = (facts.minLatitude + facts.maxLatitude) / 2
        let centreLongitude = (facts.minLongitude + facts.maxLongitude) / 2
        let local = GeoDistance.latLonToMeters(
            lat: centreLatitude,
            lon: centreLongitude,
            centerLat: facts.startLatitude,
            centerLon: facts.startLongitude
        )
        let bearingDegrees = atan2(local.x, local.z) * 180 / .pi
        guard bearingDegrees.isFinite else {
            return compassAbbreviation(forSector: 0)
        }
        // Sector 0 is centred on north, so 0° ± 22.5° maps to "N"; the
        // double remainder keeps negative bearings (west of north) in range.
        let sector = Int(floor((bearingDegrees + 22.5) / 45))
        let wrapped = ((sector % 8) + 8) % 8
        return compassAbbreviation(forSector: wrapped)
    }

    /// `String(localized:defaultValue:)` takes literal-only
    /// String.LocalizationValue arguments, so the platform split is per
    /// case rather than in a key-building helper (same limitation the
    /// `defaultDisplayName` comment records); the English default is the
    /// Linux fallback.
    private static func compassAbbreviation(forSector sector: Int) -> String {
        #if canImport(Darwin)
        switch sector {
        case 0: return String(localized: "route_group.compass.north", defaultValue: "N")
        case 1: return String(localized: "route_group.compass.northeast", defaultValue: "NE")
        case 2: return String(localized: "route_group.compass.east", defaultValue: "E")
        case 3: return String(localized: "route_group.compass.southeast", defaultValue: "SE")
        case 4: return String(localized: "route_group.compass.south", defaultValue: "S")
        case 5: return String(localized: "route_group.compass.southwest", defaultValue: "SW")
        case 6: return String(localized: "route_group.compass.west", defaultValue: "W")
        default: return String(localized: "route_group.compass.northwest", defaultValue: "NW")
        }
        #else
        switch sector {
        case 0: return "N"
        case 1: return "NE"
        case 2: return "E"
        case 3: return "SE"
        case 4: return "S"
        case 5: return "SW"
        case 6: return "W"
        default: return "NW"
        }
        #endif
    }

    /// Parenthesized disambiguator appended to a colliding base name.
    private static func disambiguatedSuffix(_ disambiguator: String) -> String {
        #if canImport(Darwin)
        let format = String(localized: "route_group.disambiguated_suffix", defaultValue: " (%@)")
        #else
        let format = " (%@)"
        #endif
        return String(format: format, disambiguator)
    }
}
