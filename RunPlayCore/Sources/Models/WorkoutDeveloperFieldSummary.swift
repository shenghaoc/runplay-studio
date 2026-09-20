import Foundation

/// Persisted record of which developer (FIT) fields a workout carries:
/// per-application provenance, per-field metadata and statistics, and the
/// diagnostics that explain what was recognised, retained, or skipped.
///
/// Unrecognised fields are retained as metadata plus min/max/mean statistics
/// — enough to answer "what is my watch recording that RunPlay Studio does
/// not understand?" — without persisting per-point value series. The source
/// file remains the record; reimporting it is the path to anything richer.
public struct WorkoutDeveloperFieldSummary: Codable, Sendable, Hashable {
    /// Identity of one developer data application (developer_data_id).
    public struct Source: Codable, Sendable, Hashable {
        public let developerDataIndex: Int
        public let developerIDHex: String?
        public let applicationIDHex: String?
        public let manufacturerID: Int?
        public let applicationVersion: Int?
    }

    public enum FieldStatus: String, Codable, Sendable, Hashable {
        /// Mapped onto route-point fields (power, dynamics).
        case mapped
        /// Recognised name with no per-point home; retained as statistics.
        case recognizedRetained
        /// Unknown field retained as metadata and statistics.
        case retained
    }

    /// One developer field's metadata and aggregate statistics.
    public struct Field: Codable, Sendable, Hashable {
        public let fieldName: String
        public let unit: String?
        public let baseType: String?
        public let scale: Double?
        public let offset: Double?
        public let developerDataIndex: Int
        /// Canonical metric key (for example "powerWatts") when recognised.
        public let mappedMetric: String?
        public let status: FieldStatus
        public let sampleCount: Int
        /// Share of the workout's route points carrying a valid value.
        public let coverage: Double
        public let minimum: Double?
        public let maximum: Double?
        public let mean: Double?
    }

    public let sources: [Source]
    public let fields: [Field]
    /// Developer data index that supplied power, when a developer field did.
    public let powerSourceDeveloperDataIndex: Int?
    /// True when power came only from the native record field.
    public let powerSourceIsNativeRecordField: Bool
    /// True when running dynamics came only from the native record fields
    /// (39/41/83/84/85). False when a developer field supplied any dynamics
    /// value, and false when the workout carries no dynamics at all.
    public let dynamicsSourceIsNativeRecordField: Bool
    /// Human-readable diagnostics: skipped values, dropped descriptions,
    /// truncation, accumulation declarations, source conflicts.
    public let notes: [String]

    /// Bounded number of per-field records persisted; fields beyond the cap
    /// are counted in `notes` rather than retained.
    public static let maximumRetainedFieldCount = 16

    /// Bounded number of field names spelled out in the non-zero-offset
    /// note; the rest are summarised as a count so one odd file cannot
    /// produce an unbounded diagnostic string.
    static let maximumNamedOffsetFields = 4

    public init(
        sources: [Source],
        fields: [Field],
        powerSourceDeveloperDataIndex: Int?,
        powerSourceIsNativeRecordField: Bool,
        dynamicsSourceIsNativeRecordField: Bool,
        notes: [String]
    ) {
        self.sources = sources
        self.fields = fields
        self.powerSourceDeveloperDataIndex = powerSourceDeveloperDataIndex
        self.powerSourceIsNativeRecordField = powerSourceIsNativeRecordField
        self.dynamicsSourceIsNativeRecordField = dynamicsSourceIsNativeRecordField
        self.notes = notes
    }
}

/// Conversion from the decode-time report to the persisted snapshot model.
extension WorkoutDeveloperFieldSummary {

    /// Build the persisted summary; returns nil when the report carries no
    /// developer data at all.
    static func make(from report: FITDeveloperFieldReport) -> WorkoutDeveloperFieldSummary? {
        guard !report.isEmpty else { return nil }

        let sources = report.sources.map { source in
            Source(
                developerDataIndex: Int(source.developerDataIndex),
                developerIDHex: source.developerIDHex,
                applicationIDHex: source.applicationIDHex,
                manufacturerID: source.manufacturerID.map(Int.init),
                applicationVersion: source.applicationVersion.map(Int.init)
            )
        }

        // Mapped fields first so the fields the app understands are never the
        // ones truncated; a stable (index, field number) order follows.
        let orderedStats = report.fieldStats.sorted { lhs, rhs in
            let lhsMapped = lhs.metric?.routePointKey != nil
            let rhsMapped = rhs.metric?.routePointKey != nil
            if lhsMapped != rhsMapped {
                return lhsMapped
            }
            if lhs.developerDataIndex != rhs.developerDataIndex {
                return lhs.developerDataIndex < rhs.developerDataIndex
            }
            return lhs.fieldNumber < rhs.fieldNumber
        }

        let pointCount = max(1, report.totalPointCount)
        var fields: [Field] = []
        fields.reserveCapacity(min(orderedStats.count, maximumRetainedFieldCount))
        var notes: [String] = []

        for stat in orderedStats {
            guard fields.count < maximumRetainedFieldCount else {
                let omitted = orderedStats.count - fields.count
                notes.append(
                    "\(omitted) additional developer field(s) not retained (cap \(maximumRetainedFieldCount))."
                )
                break
            }
            let status: FieldStatus
            switch stat.metric?.routePointKey {
            case .some: status = .mapped
            case .none where stat.metric != nil: status = .recognizedRetained
            case .none: status = .retained
            }
            fields.append(Field(
                fieldName: stat.fieldName,
                unit: stat.unit,
                baseType: stat.baseTypeName,
                scale: stat.scale,
                offset: stat.offset,
                developerDataIndex: Int(stat.developerDataIndex),
                mappedMetric: stat.metric?.routePointKey,
                status: status,
                sampleCount: stat.sampleCount,
                coverage: Double(stat.sampleCount) / Double(pointCount),
                minimum: stat.minimum,
                maximum: stat.maximum,
                mean: stat.mean
            ))
            if stat.declaresAccumulation {
                notes.append(
                    "\"\(stat.fieldName)\" declares accumulation; values were decoded as instantaneous samples."
                )
            }
        }

        // A non-default developer scale or offset is rare in the wild
        // (nearly every field ships scale 1 / offset 0), which is exactly
        // why it must be surfaced: a non-zero offset is the only case where
        // the subtract-vs-add sign convention is observable, and a non-unit
        // scale is the only case where the C++ SDK's hard-coded 1.0 (which
        // declines developer scale/offset entirely) would disagree with the
        // Swift SDK's applied conversion this importer follows. The first
        // real file carrying either should make the assumption visible
        // instead of silently decoding wrong. Scanned across every stat,
        // not just the retained ones, so a field beyond the retention cap
        // still gets flagged.
        let nonDefaultFieldNames = orderedStats
            .filter { $0.offset != 0 || $0.scale != 1 }
            .map(\.fieldName)
        if !nonDefaultFieldNames.isEmpty {
            let named = nonDefaultFieldNames.prefix(maximumNamedOffsetFields)
            let remainder = nonDefaultFieldNames.count - named.count
            let list = named.map { "\"\($0)\"" }.joined(separator: ", ")
            let suffix = remainder > 0 ? " and \(remainder) more" : ""
            notes.append(
                "\(nonDefaultFieldNames.count) developer field(s) declare a non-default scale or offset (\(list)\(suffix)); decoded as raw / scale - offset, matching the Garmin Swift SDK."
            )
        }

        if report.missingDescriptionValueCount > 0 {
            notes.append(
                "\(report.missingDescriptionValueCount) developer field value(s) skipped: no field_description message defined them."
            )
        }
        if report.invalidValueCount > 0 {
            notes.append(
                "\(report.invalidValueCount) developer field value(s) skipped: invalid or non-numeric."
            )
        }
        if report.conflictingPowerValueCount > 0 {
            notes.append(
                "\(report.conflictingPowerValueCount) power value(s) ignored: more than one developer source supplied power; the first was kept."
            )
        }
        if report.droppedValueCount > 0 {
            notes.append(
                "\(report.droppedValueCount) developer field value(s) dropped: retention limit reached."
            )
        }
        if report.droppedDescriptionCount > 0 {
            notes.append(
                "\(report.droppedDescriptionCount) field_description message(s) dropped: description table limit reached."
            )
        }

        return WorkoutDeveloperFieldSummary(
            sources: sources,
            fields: fields,
            powerSourceDeveloperDataIndex: report.powerDeveloperDataIndex.map(Int.init),
            powerSourceIsNativeRecordField:
                report.nativeRecordPowerPointCount > 0
                && report.developerPowerPointCount == 0,
            dynamicsSourceIsNativeRecordField:
                report.nativeRecordDynamicsPointCount > 0
                && report.developerDynamicsPointCount == 0,
            notes: notes
        )
    }
}
