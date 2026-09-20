import Foundation

/// Collision-aware derived display names for unnamed route groups.
///
/// `defaultDisplayName(distanceMeters:closesLoop:)` names one group from its
/// own geometry alone, so two unrelated routes with the same rounded
/// distance and the same closure produce byte-identical names ("1.2 km
/// Loop") — and `%.1f km` rounding widens the collision, since 1.16 km and
/// 1.24 km both render as 1.2 km. This extension derives names for a *set*
/// of groups at once so colliding siblings can disambiguate one another,
/// using only data already persisted in `WorkoutRouteGroupSummary` plus the
/// group's own persisted id: no geocoding, no network, no new storage (the
/// privacy model forbids the first two).
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
    ///    compass token.
    /// 3. Every other group's base name is exactly
    ///    `defaultDisplayName(distanceMeters:closesLoop:)` over its
    ///    persisted facts — loop closure from the persisted start/finish
    ///    pair measured with `GeoDistance` against
    ///    `loopClosureDistanceMeters`.
    /// 4. A base name held by only one group is emitted unchanged.
    ///    Otherwise the base name is disambiguated by escalating intrinsic
    ///    discriminators until the names differ, coarsest first:
    ///
    ///       a. an eight-point compass token — the bearing from the
    ///          representative's start point to the centre of its bounding
    ///          box (see `compassToken(for:fine:)` for why not
    ///          start-to-finish);
    ///       b. a sixteen-point sector, when the eight-point token still
    ///          collides within the base name;
    ///       c. a stable digest of the group's own id ("1.2 km Loop
    ///          (NE·7f3)") — the persisted identity, immune to import
    ///          order and membership churn — when even the fine sector
    ///          collides. Digest lengths are per group, at the shortest
    ///          of 3, 6, 8 hex digits that no sibling shares (the
    ///          abbreviated-object-name rule, as with short git object
    ///          names); a member whose full digest still collides falls
    ///          back to its own UUID string while its siblings keep
    ///          their short forms.
    ///
    ///    Every discriminator is intrinsic to the group, never its position
    ///    in a sorted list: no rank, count, or sort order participates
    ///    anywhere. Importing another colliding group — including the
    ///    historically earlier workouts a bulk archive import injects by
    ///    construction — therefore never renames the groups already named:
    ///    a name only ever *refines* (bare → coarse token → fine token →
    ///    digest) when a new collision forces it, a discriminator
    ///    lengthens only for the groups that share its prefix, and an
    ///    arrival cannot change a name it does not collide with. Names
    ///    revert when the collision goes away.
    ///
    /// The result is a pure function of the input set: no assignment
    /// depends on iteration or input order, so the same set always yields
    /// the same names in any order. (The one remaining name-changing path
    /// is inherent to facts-derived names: the store may re-pick a group's
    /// representative when membership changes, which legitimately moves
    /// that group's own base name and compass token.)
    public static func derivedDisplayNames(
        for groups: [WorkoutRouteGroup],
        loopClosureDistanceMeters: Double
    ) -> [UUID: String] {
        derivedNameDetails(
            for: groups,
            loopClosureDistanceMeters: loopClosureDistanceMeters
        ).mapValues(\.name)
    }

    /// The derivation with its structure exposed: same inputs, same
    /// behaviour as `derivedDisplayNames`, plus the tier each name reached,
    /// the base name it was built on, and — for digest-tier names — the
    /// discriminator itself. Internal, not public: consumed by the
    /// property tests that assert a name only ever refines.
    static func derivedNameDetails(
        for groups: [WorkoutRouteGroup],
        loopClosureDistanceMeters: Double
    ) -> [UUID: RouteGroupDerivedName] {
        var details: [UUID: RouteGroupDerivedName] = [:]
        details.reserveCapacity(groups.count)

        var derived: [RouteGroupDerivedNameCandidate] = []
        derived.reserveCapacity(groups.count)

        for group in groups {
            if let name = group.name, !name.isEmpty {
                details[group.id] = RouteGroupDerivedName(
                    groupID: group.id,
                    name: name,
                    baseName: name,
                    tier: .bare,
                    digestDiscriminator: nil,
                    isUserAssigned: true
                )
                continue
            }
            guard let summary = group.representativeSummary else {
                derived.append(RouteGroupDerivedNameCandidate(
                    groupID: group.id,
                    baseName: unnamedFallbackName,
                    coarseToken: nil,
                    fineToken: nil
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
            derived.append(RouteGroupDerivedNameCandidate(
                groupID: group.id,
                baseName: defaultDisplayName(
                    distanceMeters: facts.totalDistanceMeters,
                    closesLoop: closesLoop
                ),
                coarseToken: compassToken(for: facts),
                fineToken: compassToken(for: facts, fine: true)
            ))
        }

        // Escalate per base-name cluster: coarse token, then fine sector,
        // then the identity digest. Nothing here reads a sort order — the
        // discriminator a group ends up with is a function of its own
        // persisted data plus which siblings collide with it, so inserting
        // a group can only force a refinement, never a re-ranking.
        var clusters: [String: [RouteGroupDerivedNameCandidate]] = [:]
        clusters.reserveCapacity(derived.count)
        for candidate in derived {
            clusters[candidate.baseName, default: []].append(candidate)
        }

        for (baseName, cluster) in clusters {
            guard cluster.count > 1 else {
                details[cluster[0].groupID] = RouteGroupDerivedName(
                    groupID: cluster[0].groupID,
                    name: baseName,
                    baseName: baseName,
                    tier: .bare,
                    digestDiscriminator: nil,
                    isUserAssigned: false
                )
                continue
            }
            var byCoarseToken: [String: [RouteGroupDerivedNameCandidate]] = [:]
            for candidate in cluster {
                byCoarseToken[candidate.coarseToken ?? "", default: []].append(candidate)
            }
            for (_, coarseGroup) in byCoarseToken {
                guard coarseGroup.count > 1 else {
                    let candidate = coarseGroup[0]
                    if let coarseToken = candidate.coarseToken {
                        details[candidate.groupID] = RouteGroupDerivedName(
                            groupID: candidate.groupID,
                            name: baseName + disambiguatedSuffix(coarseToken),
                            baseName: baseName,
                            tier: .coarseToken,
                            digestDiscriminator: nil,
                            isUserAssigned: false
                        )
                    } else {
                        details[candidate.groupID] = RouteGroupDerivedName(
                            groupID: candidate.groupID,
                            name: baseName,
                            baseName: baseName,
                            tier: .bare,
                            digestDiscriminator: nil,
                            isUserAssigned: false
                        )
                    }
                    continue
                }
                var byFineToken: [String: [RouteGroupDerivedNameCandidate]] = [:]
                for candidate in coarseGroup {
                    byFineToken[candidate.fineToken ?? "", default: []].append(candidate)
                }
                for (_, fineGroup) in byFineToken {
                    guard fineGroup.count > 1 else {
                        let candidate = fineGroup[0]
                        if let fineToken = candidate.fineToken {
                            details[candidate.groupID] = RouteGroupDerivedName(
                                groupID: candidate.groupID,
                                name: baseName + disambiguatedSuffix(fineToken),
                                baseName: baseName,
                                tier: .fineToken,
                                digestDiscriminator: nil,
                                isUserAssigned: false
                            )
                        } else {
                            details[candidate.groupID] = RouteGroupDerivedName(
                                groupID: candidate.groupID,
                                name: baseName,
                                baseName: baseName,
                                tier: .bare,
                                digestDiscriminator: nil,
                                isUserAssigned: false
                            )
                        }
                        continue
                    }
                    assignIdentityDigestNames(fineGroup, baseName: baseName, into: &details)
                }
            }
        }

        return details
    }

    /// Appends the final-tier discriminator to every member of a group that
    /// shares one base name and one fine sector: a digest of the group's
    /// own id, at the *shortest* of 3, 6, 8 hex digits at which no other
    /// member shares this member's prefix — the abbreviated-object-name
    /// rule, applied per member. Only the groups that actually collide pay
    /// for a longer discriminator, so an arrival lengthens at most the
    /// digests it collides with; mixed lengths sit side by side safely
    /// because names compare as whole strings, exactly as with short git
    /// object names. A member whose full digest still collides (~2⁻³² per
    /// pair) falls back to its own UUID string alone, while its siblings
    /// keep their short forms. Fallback candidates with no compass token
    /// get the digest alone ("Route (7f3)").
    private static func assignIdentityDigestNames(
        _ members: [RouteGroupDerivedNameCandidate],
        baseName: String,
        into details: inout [UUID: RouteGroupDerivedName]
    ) {
        let fullDigests = members.map { stableDigestHex(for: $0.groupID) }
        for index in members.indices {
            var discriminator = members[index].groupID.uuidString
            var tier = RouteGroupDerivedNameTier.fullID
            for length in [3, 6, 8] {
                let prefix = String(fullDigests[index].prefix(length))
                let collides = members.indices.contains { other in
                    other != index && String(fullDigests[other].prefix(length)) == prefix
                }
                if !collides {
                    discriminator = prefix
                    tier = .digest
                    break
                }
            }
            let candidate = members[index]
            let disambiguator = candidate.fineToken
                .map { "\($0)·\(discriminator)" }
                ?? discriminator
            details[candidate.groupID] = RouteGroupDerivedName(
                groupID: candidate.groupID,
                name: baseName + disambiguatedSuffix(disambiguator),
                baseName: baseName,
                tier: tier,
                digestDiscriminator: discriminator,
                isUserAssigned: false
            )
        }
    }

    /// Short stable hex digest of a group id (FNV-1a over the canonical
    /// UUID string). Internal so the collision tests can construct
    /// worst-case fixtures deterministically.
    static func stableDigestHex(for groupID: UUID) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in groupID.uuidString.utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return String(format: "%08x", hash)
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

    /// Compass token for one route's facts — eight points, or sixteen when
    /// `fine`.
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
    /// coarse sectors are 45° wide (22.5° fine — the fine tier only ever
    /// separates routes that already share a coarse sector), so the token
    /// is stable across repeats. The degenerate case — a start that already
    /// sits at its extent centre — resolves to `atan2(0, 0)`, which is 0
    /// (north) by definition and stays deterministic; any residual
    /// collision is settled by the identity-digest tier.
    ///
    /// Computed through `GeoDistance.latLonToMeters`, the one shared local
    /// metre projection, so no second distance implementation exists here.
    private static func compassToken(for facts: RouteGroupingRouteFacts, fine: Bool = false) -> String {
        let centreLatitude = (facts.minLatitude + facts.maxLatitude) / 2
        let centreLongitude = (facts.minLongitude + facts.maxLongitude) / 2
        let local = GeoDistance.latLonToMeters(
            lat: centreLatitude,
            lon: centreLongitude,
            centerLat: facts.startLatitude,
            centerLon: facts.startLongitude
        )
        let bearingDegrees = atan2(local.x, local.z) * 180 / .pi
        // Non-finite bearing means corrupt persisted coordinates (the
        // start-at-centre degenerate case needs no guard — atan2(0, 0) is
        // a defined 0); map it to north rather than trap in the Int
        // conversion below.
        guard bearingDegrees.isFinite else {
            return compassAbbreviation(forSector: 0, fine: fine)
        }
        // Sector 0 is centred on north; the double remainder keeps
        // negative bearings (west of north) in range.
        let sectorCount = fine ? 16 : 8
        let sectorWidth = 360.0 / Double(sectorCount)
        let sector = Int(floor((bearingDegrees + sectorWidth / 2) / sectorWidth))
        let wrapped = ((sector % sectorCount) + sectorCount) % sectorCount
        return compassAbbreviation(forSector: wrapped, fine: fine)
    }

    /// `String(localized:defaultValue:)` takes literal-only
    /// String.LocalizationValue arguments, so the platform split is per
    /// case rather than in a key-building helper (same limitation the
    /// `defaultDisplayName` comment records); the English default is the
    /// Linux fallback.
    private static func compassAbbreviation(forSector sector: Int, fine: Bool) -> String {
        #if canImport(Darwin)
        switch (fine, sector) {
        case (false, 0), (true, 0): return String(localized: "route_group.compass.north", defaultValue: "N")
        case (false, 1): return String(localized: "route_group.compass.northeast", defaultValue: "NE")
        case (false, 2): return String(localized: "route_group.compass.east", defaultValue: "E")
        case (false, 3): return String(localized: "route_group.compass.southeast", defaultValue: "SE")
        case (false, 4): return String(localized: "route_group.compass.south", defaultValue: "S")
        case (false, 5): return String(localized: "route_group.compass.southwest", defaultValue: "SW")
        case (false, 6): return String(localized: "route_group.compass.west", defaultValue: "W")
        case (false, _): return String(localized: "route_group.compass.northwest", defaultValue: "NW")
        case (true, 1): return String(localized: "route_group.compass.north_northeast", defaultValue: "NNE")
        case (true, 2): return String(localized: "route_group.compass.northeast", defaultValue: "NE")
        case (true, 3): return String(localized: "route_group.compass.east_northeast", defaultValue: "ENE")
        case (true, 4): return String(localized: "route_group.compass.east", defaultValue: "E")
        case (true, 5): return String(localized: "route_group.compass.east_southeast", defaultValue: "ESE")
        case (true, 6): return String(localized: "route_group.compass.southeast", defaultValue: "SE")
        case (true, 7): return String(localized: "route_group.compass.south_southeast", defaultValue: "SSE")
        case (true, 8): return String(localized: "route_group.compass.south", defaultValue: "S")
        case (true, 9): return String(localized: "route_group.compass.south_southwest", defaultValue: "SSW")
        case (true, 10): return String(localized: "route_group.compass.southwest", defaultValue: "SW")
        case (true, 11): return String(localized: "route_group.compass.west_southwest", defaultValue: "WSW")
        case (true, 12): return String(localized: "route_group.compass.west", defaultValue: "W")
        case (true, 13): return String(localized: "route_group.compass.west_northwest", defaultValue: "WNW")
        case (true, 14): return String(localized: "route_group.compass.northwest", defaultValue: "NW")
        default: return String(localized: "route_group.compass.north_northwest", defaultValue: "NNW")
        }
        #else
        let coarse = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let fineWind = [
            "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
            "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
        ]
        let names = fine ? fineWind : coarse
        return names[min(max(sector, 0), names.count - 1)]
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

/// One derived-naming candidate: the base name plus both compass tiers
/// for a group that needs disambiguation (`nil` tokens for the
/// summary-less fallback).
private struct RouteGroupDerivedNameCandidate {
    let groupID: UUID
    let baseName: String
    let coarseToken: String?
    let fineToken: String?
}

/// Disambiguation tier a derived name reached, coarsest to finest —
/// the property tests assert a group's tier never decreases when new
/// groups arrive. Internal, not public.
enum RouteGroupDerivedNameTier: Int, Comparable {
    case bare = 0
    case coarseToken = 1
    case fineToken = 2
    case digest = 3
    case fullID = 4

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One derived name plus the pieces the property tests reason about: the
/// base name it was built on, the tier reached, and — for digest-tier
/// names — the discriminator itself (hex prefix, or the UUID string at
/// the terminal corner). User-assigned names are flagged rather than
/// tiered, because they take no part in the rule. Internal, not public.
struct RouteGroupDerivedName: Equatable {
    let groupID: UUID
    let name: String
    let baseName: String
    let tier: RouteGroupDerivedNameTier
    let digestDiscriminator: String?
    let isUserAssigned: Bool
}
