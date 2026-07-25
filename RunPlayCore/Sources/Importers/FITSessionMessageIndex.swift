import Foundation

/// One-pass association of a decoded FIT container's records, timer events, and
/// laps with its sessions.
///
/// Built **once** per container. Every selected session then reads its own
/// messages from the prepared buckets, which is what keeps a batch import at
/// `O(r + e + l + s log s)` instead of re-filtering every message array per
/// session.
public struct FITSessionMessageIndex: Sendable {

    /// How the container's messages were associated.
    public enum Mode: String, Hashable, Sendable {
        /// No session messages at all — the legacy whole-file fallback.
        case legacyNoSessions
        /// Exactly one session; pre-existing single-session semantics apply.
        case singleSession
        /// Two or more sessions; bounded timestamp attribution applies.
        case multiSession
    }

    public let mode: Mode
    public let decodedFile: FITDecodedFile
    public let prepared: FITPreparedSessions

    private let recordBuckets: [[Int]]
    private let eventBuckets: [[Int]]
    private let lapBuckets: [[Int]]

    public var sessionCount: Int { decodedFile.sessions.count }

    // MARK: - Build

    public static func build(decodedFile: FITDecodedFile) -> FITSessionMessageIndex {
        let sessions = decodedFile.sessions

        if sessions.isEmpty {
            return FITSessionMessageIndex(
                mode: .legacyNoSessions,
                decodedFile: decodedFile,
                prepared: FITPreparedSessions(
                    ranges: [],
                    problems: [],
                    ambiguousIndexes: [],
                    orderedRanges: []
                ),
                recordBuckets: [],
                eventBuckets: [],
                lapBuckets: []
            )
        }

        let prepared = FITSessionAttribution.prepare(sessions: sessions)

        if sessions.count == 1 {
            // Preserve the exact pre-existing single-session filter, including
            // its open upper bound when the session timestamp is invalid and
            // its "keep everything" fallback when no start can be resolved.
            let session = sessions[0]
            let start = FITSessionAttribution.resolveStart(of: session)
            let end = FITSessionAttribution.resolveDeclaredEnd(of: session)

            func withinSession(_ rawTimestamp: UInt32?) -> Bool {
                guard let start else { return true }
                guard let timestamp = FITParser.timestampIfValid(rawTimestamp) else { return false }
                if timestamp < start { return false }
                if let end, timestamp > end { return false }
                return true
            }

            let records = decodedFile.records.indices.filter {
                withinSession(decodedFile.records[$0].timestamp)
            }
            let events = decodedFile.events.indices.filter {
                withinSession(decodedFile.events[$0].timestamp)
            }
            // With one session there is no cross-session ambiguity, so keep even
            // boundaryless lap messages and let the analyzer diagnose them —
            // unless the profile supplied a complete, unambiguous lap range.
            let indexClaimed = FITSessionAttribution.attributeLaps(
                laps: decodedFile.laps,
                sessions: sessions,
                prepared: prepared
            )
            let laps = FITSessionAttribution.hasReliableLapIndexMetadata(
                session: session,
                laps: decodedFile.laps
            )
                ? indexClaimed[0]
                : Array(decodedFile.laps.indices)

            return FITSessionMessageIndex(
                mode: .singleSession,
                decodedFile: decodedFile,
                prepared: prepared,
                recordBuckets: [records],
                eventBuckets: [events],
                lapBuckets: [laps]
            )
        }

        let recordOwners = FITSessionAttribution.attributeOwners(
            timestamps: FITSessionAttribution.recordTimestamps(decodedFile.records),
            orderedRanges: prepared.orderedRanges
        )
        let eventOwners = FITSessionAttribution.attributeOwners(
            timestamps: FITSessionAttribution.eventTimestamps(decodedFile.events),
            orderedRanges: prepared.orderedRanges
        )

        return FITSessionMessageIndex(
            mode: .multiSession,
            decodedFile: decodedFile,
            prepared: prepared,
            recordBuckets: FITSessionAttribution.buckets(
                owners: recordOwners,
                sessionCount: sessions.count
            ),
            eventBuckets: FITSessionAttribution.buckets(
                owners: eventOwners,
                sessionCount: sessions.count
            ),
            lapBuckets: FITSessionAttribution.attributeLaps(
                laps: decodedFile.laps,
                sessions: sessions,
                prepared: prepared
            )
        )
    }

    // MARK: - Session-scoped access

    /// Records attributed to one session, in FIT source order.
    /// Legacy containers with no session messages return every record.
    public func records(for sessionIndex: Int) -> [FITRecordMessage] {
        guard mode != .legacyNoSessions else { return decodedFile.records }
        guard recordBuckets.indices.contains(sessionIndex) else { return [] }
        return recordBuckets[sessionIndex].map { decodedFile.records[$0] }
    }

    /// Timer events attributed to one session, in FIT source order.
    ///
    /// Legacy containers return none: the pre-existing fallback path never
    /// applied timer segmentation without a session.
    public func events(for sessionIndex: Int) -> [FITEventMessage] {
        guard mode != .legacyNoSessions else { return [] }
        guard eventBuckets.indices.contains(sessionIndex) else { return [] }
        return eventBuckets[sessionIndex].map { decodedFile.events[$0] }
    }

    /// Lap messages attributed to one session, in FIT source order.
    public func laps(for sessionIndex: Int) -> [FITLapMessage] {
        guard mode != .legacyNoSessions else { return decodedFile.laps }
        guard lapBuckets.indices.contains(sessionIndex) else { return [] }
        return lapBuckets[sessionIndex].map { decodedFile.laps[$0] }
    }

    /// Number of attributed records carrying usable GPS coordinates.
    public func gpsRecordCount(for sessionIndex: Int) -> Int {
        guard mode != .legacyNoSessions else {
            return decodedFile.records.count(where: Self.hasUsableCoordinates)
        }
        guard recordBuckets.indices.contains(sessionIndex) else { return 0 }
        return recordBuckets[sessionIndex].count(where: {
            Self.hasUsableCoordinates(decodedFile.records[$0])
        })
    }

    public func lapCount(for sessionIndex: Int) -> Int {
        guard mode != .legacyNoSessions else { return decodedFile.laps.count }
        guard lapBuckets.indices.contains(sessionIndex) else { return 0 }
        return lapBuckets[sessionIndex].count
    }

    /// Records excluded because they carry no timestamp that could attribute
    /// them to any session. Multi-session mode only; reported as a warning.
    public func unattributedRecordCount() -> Int {
        guard mode == .multiSession else { return 0 }
        let attributed = recordBuckets.reduce(0) { $0 + $1.count }
        return decodedFile.records.count - attributed
    }

    // MARK: - Private

    private static func hasUsableCoordinates(_ record: FITRecordMessage) -> Bool {
        guard let latitude = record.positionLat, let longitude = record.positionLong else {
            return false
        }
        guard latitude != FITParser.invalidCoordinate,
              longitude != FITParser.invalidCoordinate
        else {
            return false
        }
        return GeoDistance.isValidCoordinate(
            lat: FITParser.semicirclesToDegrees(latitude),
            lon: FITParser.semicirclesToDegrees(longitude)
        )
    }

}
