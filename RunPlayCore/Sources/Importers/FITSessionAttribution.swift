import Foundation

/// Why a session could not be given a reliable time range.
public enum FITSessionBoundaryProblem: String, Hashable, Sendable {
    /// No valid `start_time`, and no valid end timestamp plus elapsed total.
    case missingStart
    /// No valid session `timestamp`, and no reliably ordered next session.
    case missingEnd
    /// The resolved end precedes the resolved start.
    case invalidOrder

    public var detail: String {
        switch self {
        case .missingStart:
            return "This session has no usable start time."
        case .missingEnd:
            return "This session has no usable end time."
        case .invalidOrder:
            return "This session's end time precedes its start time."
        }
    }
}

/// A resolved, half-open FIT session time range.
///
/// `upperExclusive` is the single value the attribution walk compares against,
/// so the shared-boundary rule is applied once during preparation rather than
/// re-derived at every record.
public struct FITSessionRange: Hashable, Sendable {
    public let sourceIndex: Int
    /// Inclusive lower bound.
    public let start: UInt32
    /// Resolved end for display. Inclusive unless a later session starts here.
    public let end: UInt32
    /// Exclusive upper bound used for attribution.
    public let upperExclusive: UInt32
    /// True when `end` was derived from the next session's start rather than
    /// read from this session's own `timestamp` field.
    public let endWasDerived: Bool
}

/// Session ranges plus the diagnostics needed to classify each candidate.
public struct FITPreparedSessions: Sendable {
    /// Resolved range per source index; `nil` when the session is unusable.
    public let ranges: [FITSessionRange?]
    /// Boundary problem per source index; `nil` when the range resolved.
    public let problems: [FITSessionBoundaryProblem?]
    /// Source indexes whose ranges materially overlap another session.
    public let ambiguousIndexes: Set<Int>
    /// Non-ambiguous ranges sorted by `(start, upperExclusive, sourceIndex)`.
    /// Guaranteed pairwise non-overlapping, so one advancing cursor is correct.
    public let orderedRanges: [FITSessionRange]

    public func range(at sourceIndex: Int) -> FITSessionRange? {
        guard ranges.indices.contains(sourceIndex) else { return nil }
        return ranges[sourceIndex]
    }

    public func problem(at sourceIndex: Int) -> FITSessionBoundaryProblem? {
        guard problems.indices.contains(sourceIndex) else { return nil }
        return problems[sourceIndex]
    }

    public var sessionCount: Int { ranges.count }
}

/// Resolves FIT session boundaries and attributes records, timer events, and
/// laps to individual sessions without ever scanning records × sessions.
///
/// Complexity after `prepare` (s sessions, n items):
/// - preparation: `O(s log s)`
/// - attribution: `O(n + s)` when source order is chronological, otherwise
///   `O(n log n + s)` for one index sort.
public enum FITSessionAttribution {

    /// Sentinel owner value meaning "not attributable to any session".
    public static let unattributed: Int32 = -1

    // MARK: - Boundary resolution

    /// FIT session messages normally carry `start_time`; when they do not,
    /// derive it from the end timestamp and profile-scaled total elapsed time.
    /// Returning nil keeps imports fail-safe rather than merging records that
    /// cannot be attributed to one session.
    public static func resolveStart(of session: FITSessionMessage) -> UInt32? {
        if let startTime = FITParser.timestampIfValid(session.startTime) {
            return startTime
        }
        guard let endTime = FITParser.timestampIfValid(session.timestamp),
              let totalElapsedMilliseconds = session.totalElapsedTime,
              totalElapsedMilliseconds != FITParser.invalidUint32
        else {
            return nil
        }
        let elapsedSeconds = totalElapsedMilliseconds / 1_000
        guard elapsedSeconds <= endTime else { return nil }
        return endTime - elapsedSeconds
    }

    /// The session's own end timestamp, if the profile supplied a valid one.
    public static func resolveDeclaredEnd(of session: FITSessionMessage) -> UInt32? {
        FITParser.timestampIfValid(session.timestamp)
    }

    /// Resolve every session range, detect material overlap, and apply the
    /// shared-boundary rule.
    ///
    /// Boundary policy: session start is inclusive; a session end is inclusive
    /// only when it does not coincide with a later session's start. When two
    /// adjacent sessions share a boundary timestamp the boundary record belongs
    /// to the **later** session, so one sample can never contaminate both.
    public static func prepare(sessions: [FITSessionMessage]) -> FITPreparedSessions {
        let count = sessions.count
        var starts = [UInt32?](repeating: nil, count: count)
        var declaredEnds = [UInt32?](repeating: nil, count: count)
        for index in 0..<count {
            starts[index] = resolveStart(of: sessions[index])
            declaredEnds[index] = resolveDeclaredEnd(of: sessions[index])
        }

        var ranges = [FITSessionRange?](repeating: nil, count: count)
        var problems = [FITSessionBoundaryProblem?](repeating: nil, count: count)

        for index in 0..<count {
            guard let start = starts[index] else {
                problems[index] = .missingStart
                continue
            }

            let end: UInt32
            let endWasDerived: Bool
            if let declared = declaredEnds[index] {
                end = declared
                endWasDerived = false
            } else if index + 1 < count,
                      let nextStart = starts[index + 1],
                      nextStart >= start {
                // Conservative bounded fallback: only the immediately following
                // session, and only when it is reliably ordered. The next
                // session owns its own start, so this bound is exclusive.
                end = nextStart
                endWasDerived = true
            } else {
                problems[index] = .missingEnd
                continue
            }

            guard end >= start else {
                problems[index] = .invalidOrder
                continue
            }

            ranges[index] = FITSessionRange(
                sourceIndex: index,
                start: start,
                end: end,
                upperExclusive: endWasDerived ? end : exclusiveBound(after: end),
                endWasDerived: endWasDerived
            )
        }

        // Sort a copy for the boundary and overlap passes. Source order is
        // preserved separately in `ranges` and drives display and staging.
        var sorted = ranges.compactMap { $0 }
        sorted.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.upperExclusive != rhs.upperExclusive {
                return lhs.upperExclusive < rhs.upperExclusive
            }
            return lhs.sourceIndex < rhs.sourceIndex
        }

        // Shared boundary: when an inclusive end coincides with another
        // session's start, demote it to exclusive so the later session owns the
        // sample. Ranges are start-sorted, so a start equal to a strictly later
        // `end` value always belongs to a range that sorts after this one.
        var startCounts: [UInt32: Int] = [:]
        for range in sorted {
            startCounts[range.start, default: 0] += 1
        }
        for position in sorted.indices {
            let current = sorted[position]
            // A zero-length range must not demote itself out of existence:
            // only another session starting on this boundary triggers the rule.
            let ownStartAtBoundary = current.start == current.end ? 1 : 0
            guard !current.endWasDerived,
                  startCounts[current.end, default: 0] > ownStartAtBoundary
            else {
                continue
            }
            let demoted = FITSessionRange(
                sourceIndex: current.sourceIndex,
                start: current.start,
                end: current.end,
                upperExclusive: current.end,
                endWasDerived: current.endWasDerived
            )
            sorted[position] = demoted
            ranges[current.sourceIndex] = demoted
        }

        // Material overlap. Because `sorted` is ascending by start, range i
        // overlaps something iff it starts before the maximum upper bound of
        // all preceding ranges, or the next range starts before its own upper
        // bound. Any later overlapping range implies the immediate successor
        // overlaps too, so these two O(1) checks are exhaustive.
        var ambiguous = Set<Int>()
        var prefixMaxUpper: UInt32 = 0
        for position in sorted.indices {
            let current = sorted[position]
            if position > 0, current.start < prefixMaxUpper {
                ambiguous.insert(current.sourceIndex)
            }
            if position + 1 < sorted.count,
               sorted[position + 1].start < current.upperExclusive {
                ambiguous.insert(current.sourceIndex)
                ambiguous.insert(sorted[position + 1].sourceIndex)
            }
            prefixMaxUpper = max(prefixMaxUpper, current.upperExclusive)
        }

        let orderedRanges = sorted.filter { !ambiguous.contains($0.sourceIndex) }

        return FITPreparedSessions(
            ranges: ranges,
            problems: problems,
            ambiguousIndexes: ambiguous,
            orderedRanges: orderedRanges
        )
    }

    // MARK: - Attribution walk

    /// Assign each timestamped item to at most one session.
    ///
    /// - Parameter timestamps: One entry per item in source order. `nil` marks
    ///   an item that carries no usable timestamp; such items are never guessed
    ///   into a session.
    /// - Returns: Owner source index per item, or `unattributed`.
    public static func attributeOwners(
        timestamps: [UInt32?],
        orderedRanges: [FITSessionRange]
    ) -> [Int32] {
        var owners = [Int32](repeating: unattributed, count: timestamps.count)
        guard !orderedRanges.isEmpty, !timestamps.isEmpty else { return owners }

        if isChronological(timestamps) {
            var cursor = orderedRanges.startIndex
            for index in timestamps.indices {
                guard let timestamp = timestamps[index] else { continue }
                while cursor < orderedRanges.endIndex,
                      timestamp >= orderedRanges[cursor].upperExclusive {
                    cursor += 1
                }
                guard cursor < orderedRanges.endIndex else { break }
                if timestamp >= orderedRanges[cursor].start {
                    owners[index] = Int32(orderedRanges[cursor].sourceIndex)
                }
            }
            return owners
        }

        // Source order is not chronological. Sort an index permutation once so
        // the walk stays a single advancing cursor rather than a nested scan.
        var order = timestamps.indices.filter { timestamps[$0] != nil }
        order.sort { lhs, rhs in
            let left = timestamps[lhs] ?? 0
            let right = timestamps[rhs] ?? 0
            if left != right { return left < right }
            return lhs < rhs
        }

        var cursor = orderedRanges.startIndex
        for index in order {
            guard let timestamp = timestamps[index] else { continue }
            while cursor < orderedRanges.endIndex,
                  timestamp >= orderedRanges[cursor].upperExclusive {
                cursor += 1
            }
            guard cursor < orderedRanges.endIndex else { break }
            if timestamp >= orderedRanges[cursor].start {
                owners[index] = Int32(orderedRanges[cursor].sourceIndex)
            }
        }
        return owners
    }

    /// Group item indexes by owning session in **one** source-order pass.
    ///
    /// Building buckets for every session at once is what keeps the overall
    /// cost `O(n + s)`; filtering the item array once per session would be the
    /// `records × sessions` scan this design exists to avoid.
    public static func buckets(
        owners: [Int32],
        sessionCount: Int
    ) -> [[Int]] {
        var buckets = [[Int]](repeating: [], count: sessionCount)
        for index in owners.indices {
            let owner = owners[index]
            guard owner >= 0, Int(owner) < sessionCount else { continue }
            buckets[Int(owner)].append(index)
        }
        return buckets
    }

    // MARK: - Typed helpers

    public static func recordTimestamps(_ records: [FITRecordMessage]) -> [UInt32?] {
        records.map { FITParser.timestampIfValid($0.timestamp) }
    }

    public static func eventTimestamps(_ events: [FITEventMessage]) -> [UInt32?] {
        events.map { FITParser.timestampIfValid($0.timestamp) }
    }

    /// Lap membership anchors on `start_time`, falling back to the lap's end
    /// timestamp, mirroring the single-session importer.
    public static func lapTimestamps(_ laps: [FITLapMessage]) -> [UInt32?] {
        laps.map { lap in
            FITParser.timestampIfValid(lap.startTime) ?? FITParser.timestampIfValid(lap.timestamp)
        }
    }

    // MARK: - Lap association

    /// Associate laps with sessions, preferring FIT index metadata.
    ///
    /// Priority: `first_lap_index` + `number_of_laps` (lower 12 bits of
    /// `message_index`), then lap timestamp range, then no attribution.
    /// A lap array index is claimed at most once across all sessions.
    ///
    /// - Returns: Lap array indexes per session source index, in source order.
    public static func attributeLaps(
        laps: [FITLapMessage],
        sessions: [FITSessionMessage],
        prepared: FITPreparedSessions
    ) -> [[Int]] {
        let sessionCount = sessions.count
        guard sessionCount > 0 else { return [] }
        guard !laps.isEmpty else { return [[Int]](repeating: [], count: sessionCount) }

        // One pass: lower-12-bit ordinal → lap array indexes.
        var lapsByOrdinal: [Int: [Int]] = [:]
        for (arrayIndex, lap) in laps.enumerated() {
            guard let rawIndex = lap.messageIndex, rawIndex != FITParser.invalidUint16 else {
                continue
            }
            lapsByOrdinal[Int(rawIndex & 0x0FFF), default: []].append(arrayIndex)
        }

        // Tentative index-metadata claims.
        var tentativeClaims = [[Int]?](repeating: nil, count: sessionCount)
        var claimCount = [Int](repeating: 0, count: laps.count)
        for sessionIndex in 0..<sessionCount {
            let session = sessions[sessionIndex]
            guard let firstLapIndex = session.firstLapIndex,
                  firstLapIndex != FITParser.invalidUint16,
                  let numberOfLaps = session.numberOfLaps,
                  numberOfLaps != FITParser.invalidUint16
            else {
                continue
            }
            let lowerBound = Int(firstLapIndex & 0x0FFF)
            let upperBound = lowerBound + Int(numberOfLaps)
            var matched: [Int] = []
            var matchedOrdinals = Set<Int>()
            for ordinal in lowerBound..<upperBound {
                guard let arrayIndexes = lapsByOrdinal[ordinal] else { continue }
                matched.append(contentsOf: arrayIndexes)
                matchedOrdinals.insert(ordinal)
            }
            // Same completeness rule as the single-session importer: a partial
            // or duplicated ordinal range is not reliable metadata.
            guard matched.count == Int(numberOfLaps),
                  matchedOrdinals.count == Int(numberOfLaps)
            else {
                continue
            }
            matched.sort()
            tentativeClaims[sessionIndex] = matched
            for arrayIndex in matched {
                claimCount[arrayIndex] += 1
            }
        }

        // Drop any claim that shares a lap with another session's claim.
        var indexClaims = [[Int]?](repeating: nil, count: sessionCount)
        var claimedLapIndexes = Set<Int>()
        var claimedBySession = [Int](repeating: -1, count: laps.count)
        for sessionIndex in 0..<sessionCount {
            guard let claim = tentativeClaims[sessionIndex] else { continue }
            guard claim.allSatisfy({ claimCount[$0] == 1 }) else { continue }
            indexClaims[sessionIndex] = claim
            for arrayIndex in claim {
                claimedLapIndexes.insert(arrayIndex)
                claimedBySession[arrayIndex] = sessionIndex
            }
        }

        // Timestamp fallback only for sessions without reliable index metadata,
        // and only over laps no session claimed by index.
        let owners = attributeOwners(
            timestamps: lapTimestamps(laps),
            orderedRanges: prepared.orderedRanges
        )

        var result = [[Int]](repeating: [], count: sessionCount)
        for arrayIndex in laps.indices {
            let claimingSession = claimedBySession[arrayIndex]
            if claimingSession >= 0 {
                result[claimingSession].append(arrayIndex)
                continue
            }
            let owner = owners[arrayIndex]
            guard owner >= 0, Int(owner) < sessionCount else { continue }
            // A session that declared its own lap range does not also absorb
            // stray laps by timestamp.
            guard indexClaims[Int(owner)] == nil else { continue }
            result[Int(owner)].append(arrayIndex)
        }
        return result
    }

    // MARK: - Private helpers

    private static func exclusiveBound(after end: UInt32) -> UInt32 {
        end == UInt32.max ? UInt32.max : end + 1
    }

    private static func isChronological(_ timestamps: [UInt32?]) -> Bool {
        var previous: UInt32?
        for timestamp in timestamps {
            guard let timestamp else { continue }
            if let previous, timestamp < previous { return false }
            previous = timestamp
        }
        return true
    }
}
