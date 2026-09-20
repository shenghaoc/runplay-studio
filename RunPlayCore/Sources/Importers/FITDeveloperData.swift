import Foundation

// MARK: - Field Description (Global Message 206)

/// Decoded FIT `field_description` message (global message 206).
///
/// Describes one developer field: its base type, display name, unit, and the
/// scale/offset that convert raw record values into physical values. Field
/// numbers and base types follow the official FIT profile.
public struct FITFieldDescriptionMessage: Sendable, Equatable {
    public var developerDataIndex: UInt8?      // field 0
    public var fieldDefinitionNumber: UInt8?   // field 1
    /// Raw `fit_base_type_id`. The enum's value equals the binary base-type
    /// byte (for example 0x84 for uint16), so it maps directly onto
    /// `FITBaseType`.
    public var baseTypeID: UInt8?              // field 2
    public var fieldName: String?              // field 3
    public var array: UInt8?                   // field 4
    public var components: String?             // field 5
    public var scale: UInt8?                   // field 6
    public var offset: Int8?                   // field 7
    public var units: String?                  // field 8
    public var bits: String?                   // field 9
    public var accumulate: String?             // field 10
    public var baseUnitID: UInt16?             // field 13, fit_base_unit enum
    public var nativeMesgNum: UInt16?          // field 14
    public var nativeFieldNum: UInt8?          // field 15

    public init() {}

    public var baseType: FITBaseType? {
        baseTypeID.flatMap(FITBaseType.init(rawValue:))
    }

    /// Effective scale; a missing or zero scale is treated as 1 so a corrupt
    /// description cannot produce a division by zero.
    public var effectiveScale: Double {
        guard let scale, scale > 0 else { return 1 }
        return Double(scale)
    }

    /// Effective offset; missing means 0.
    public var effectiveOffset: Double {
        offset.map(Double.init) ?? 0
    }

    /// Whether the description declares accumulation semantics. Accumulate
    /// math is out of scope: values are decoded as instantaneous samples and
    /// the flag is surfaced through diagnostics instead.
    public var declaresAccumulation: Bool {
        guard let accumulate else { return false }
        return !accumulate.isEmpty && accumulate != "0"
    }

    /// Resolved display unit. The `units` string is authoritative when the
    /// device populated it; otherwise the `fit_base_unit_id` is resolved
    /// through the official `fit_base_unit` enum, verified against the
    /// Garmin Swift SDK's generated `Profile/Types/FitBaseUnit.swift`
    /// (Profile 21.214.0): `other = 0`, `kilogram = 1`, `pound = 2`,
    /// `invalid = 0xFFFF`. `other` carries no unit information, so it
    /// resolves to nil rather than a placeholder string; an id outside the
    /// enum is retained raw so a future profile addition stays visible
    /// instead of being silently dropped.
    public var resolvedUnit: String? {
        if let units, !units.isEmpty {
            return units
        }
        guard let baseUnitID, baseUnitID != FITParser.invalidUint16 else { return nil }
        switch baseUnitID {
        case 0: return nil          // fit_base_unit "other": no unit named
        case 1: return "kg"
        case 2: return "lb"
        default: return "fit_base_unit:\(baseUnitID)"
        }
    }
}

// MARK: - Developer Data ID (Global Message 207)

/// Decoded FIT `developer_data_id` message (global message 207).
///
/// Identifies the application that owns one `developer_data_index`, carrying
/// up to two 16-byte GUIDs plus manufacturer and application version.
public struct FITDeveloperDataIDMessage: Sendable, Equatable {
    public var developerID: Data?         // field 0, byte[16]
    public var applicationID: Data?       // field 1, byte[16]
    public var manufacturerID: UInt16?    // field 2
    public var developerDataIndex: UInt8? // field 3
    public var applicationVersion: UInt32? // field 4

    public init() {}
}

// MARK: - Captured Record Values

/// One developer field payload captured from a record data message.
///
/// The parser retains raw bytes because a `field_description` message may
/// legally appear after the records that reference it; values are resolved
/// once the whole file has been decoded.
public struct FITRecordDeveloperFieldValue: Sendable, Equatable {
    public let developerDataIndex: UInt8
    public let fieldNumber: UInt8
    public let bytes: Data
    public let littleEndian: Bool

    public init(
        developerDataIndex: UInt8,
        fieldNumber: UInt8,
        bytes: Data,
        littleEndian: Bool
    ) {
        self.developerDataIndex = developerDataIndex
        self.fieldNumber = fieldNumber
        self.bytes = bytes
        self.littleEndian = littleEndian
    }
}

// MARK: - Recognition Registry

/// Canonical developer-field metrics RunPlay Studio can interpret.
///
/// Matching is name-based by design. Field names are stable across vendors
/// (Stryd, Garmin Connect IQ running power, COROS running dynamics), while
/// application IDs are vendor constants that cannot be verified without real
/// device files. A field from an unknown application with sane names is
/// therefore still recognized; the raw application identity is retained for
/// provenance either way.
public enum FITDeveloperMetric: String, CaseIterable, Sendable {
    case power
    case formPower
    case legSpringStiffness
    case groundContactTime
    case verticalOscillation
    case verticalRatio
    case stanceTimeBalance
    case stepLength

    /// Recognized field-name spellings, normalized (lowercase, single spaces).
    public var recognizedNames: [String] {
        switch self {
        case .power:
            return ["power"]
        case .formPower:
            return ["form power"]
        case .legSpringStiffness:
            return ["leg spring stiffness", "lss"]
        case .groundContactTime:
            return ["ground time", "ground contact time", "stance time", "gct"]
        case .verticalOscillation:
            return ["vertical oscillation"]
        case .verticalRatio:
            return ["vertical ratio"]
        case .stanceTimeBalance:
            return ["stance time balance"]
        case .stepLength:
            return ["step length"]
        }
    }

    /// Match a raw field name against the registry.
    public static func match(fieldName: String) -> FITDeveloperMetric? {
        let normalized = normalize(fieldName)
        guard !normalized.isEmpty else { return nil }
        return allCases.first { metric in
            metric.recognizedNames.contains(normalized)
        }
    }

    /// Normalize a field name: case-insensitive, trimmed, and with every
    /// run of any whitespace character (spaces, tabs, newlines) collapsed
    /// to a single space. Vendor spellings cannot be validated against real
    /// device files yet, so matching tolerates the formatting differences
    /// a device encoder can introduce without changing the name.
    public static func normalize(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The persisted RoutePoint field this metric feeds, when it has one.
    /// `formPower` and `legSpringStiffness` are recognized names with no
    /// per-point home; they are retained as summary statistics.
    public var routePointKey: String? {
        switch self {
        case .power: return "powerWatts"
        case .groundContactTime: return "groundContactTimeMilliseconds"
        case .verticalOscillation: return "verticalOscillationMillimeters"
        case .verticalRatio: return "verticalRatioPercent"
        case .stanceTimeBalance: return "stanceTimeBalancePercent"
        case .stepLength: return "stepLengthMeters"
        case .formPower, .legSpringStiffness: return nil
        }
    }
}

// MARK: - Resolution

/// Developer field values resolved for one record.
struct FITDeveloperPointValues: Sendable, Equatable {
    var powerWatts: Double?
    var groundContactTimeMilliseconds: Double?
    var verticalOscillationMillimeters: Double?
    var verticalRatioPercent: Double?
    var stanceTimeBalancePercent: Double?
    var stepLengthMeters: Double?
    /// The developer data index that supplied `powerWatts`, when it did.
    var powerDeveloperDataIndex: UInt8?

    /// Whether any recognized developer field supplied a running-dynamics
    /// value on this record (power excluded).
    var hasAnyDynamics: Bool {
        groundContactTimeMilliseconds != nil
            || verticalOscillationMillimeters != nil
            || verticalRatioPercent != nil
            || stanceTimeBalancePercent != nil
            || stepLengthMeters != nil
    }
}

/// Aggregate outcome of resolving one session's developer fields.
struct FITDeveloperFieldResolution: Sendable {
    var pointValues: [FITDeveloperPointValues]
    var fieldStats: [FITDeveloperFieldReport.FieldStat]
    var missingDescriptionValueCount: Int
    var invalidValueCount: Int
    var conflictingPowerValueCount: Int
}

/// Resolves captured developer field bytes into physical values using the
/// file-wide field-description table, and aggregates per-field statistics.
///
/// Conversion follows the FIT protocol convention
/// `physical = raw / scale - offset` (scale defaults to 1, offset to 0) —
/// the same convention this importer already applies to profile fields such
/// as altitude (`FITParser.scaledAltitudeToMeters`). The sign is unanimous
/// across the official SDKs; whether the conversion applies to developer
/// fields at all is not. See `physicalValue(of:description:)`.
/// Invalid sentinels per base type are treated as missing values.
enum FITDeveloperFieldResolver {

    static func resolve(
        records: [FITRecordMessage],
        descriptions: [FITFieldDescriptionMessage]
    ) -> FITDeveloperFieldResolution {
        // First description per (developer_data_index, field_definition_number)
        // wins; later duplicates are ignored deterministically.
        var descriptionTable: [UInt16: FITFieldDescriptionMessage] = [:]
        descriptionTable.reserveCapacity(descriptions.count)
        for description in descriptions {
            guard let developerDataIndex = description.developerDataIndex,
                  let fieldDefinitionNumber = description.fieldDefinitionNumber
            else {
                continue
            }
            let key = descriptionKey(
                developerDataIndex: developerDataIndex,
                fieldNumber: fieldDefinitionNumber
            )
            if descriptionTable[key] == nil {
                descriptionTable[key] = description
            }
        }

        var statAccumulators: [UInt16: FieldStatAccumulator] = [:]
        var pointValues: [FITDeveloperPointValues] = []
        pointValues.reserveCapacity(records.count)
        var missingDescriptionValueCount = 0
        var invalidValueCount = 0
        var conflictingPowerValueCount = 0

        for record in records {
            var values = FITDeveloperPointValues()

            for raw in record.developerFields {
                let key = descriptionKey(
                    developerDataIndex: raw.developerDataIndex,
                    fieldNumber: raw.fieldNumber
                )
                guard let description = descriptionTable[key] else {
                    missingDescriptionValueCount += 1
                    continue
                }
                guard let physical = physicalValue(of: raw, description: description) else {
                    invalidValueCount += 1
                    continue
                }

                let statKey = key
                var accumulator = statAccumulators[statKey]
                    ?? FieldStatAccumulator(description: description)
                accumulator.add(physical)
                statAccumulators[statKey] = accumulator

                guard let metric = FITDeveloperMetric.match(
                    fieldName: description.fieldName ?? ""
                ) else {
                    continue
                }
                switch metric {
                case .power:
                    if values.powerWatts == nil {
                        values.powerWatts = physical
                        values.powerDeveloperDataIndex = raw.developerDataIndex
                    } else {
                        conflictingPowerValueCount += 1
                    }
                case .groundContactTime:
                    if values.groundContactTimeMilliseconds == nil {
                        values.groundContactTimeMilliseconds = physical
                    }
                case .verticalOscillation:
                    if values.verticalOscillationMillimeters == nil {
                        values.verticalOscillationMillimeters = physical
                    }
                case .verticalRatio:
                    if values.verticalRatioPercent == nil {
                        values.verticalRatioPercent = physical
                    }
                case .stanceTimeBalance:
                    if values.stanceTimeBalancePercent == nil {
                        values.stanceTimeBalancePercent = physical
                    }
                case .stepLength:
                    if values.stepLengthMeters == nil {
                        values.stepLengthMeters = physical
                    }
                case .formPower, .legSpringStiffness:
                    break
                }
            }

            pointValues.append(values)
        }

        let fieldStats = statAccumulators
            .values
            .sorted { lhs, rhs in
                if lhs.developerDataIndex != rhs.developerDataIndex {
                    return lhs.developerDataIndex < rhs.developerDataIndex
                }
                return lhs.fieldNumber < rhs.fieldNumber
            }
            .map { $0.finalize() }

        return FITDeveloperFieldResolution(
            pointValues: pointValues,
            fieldStats: fieldStats,
            missingDescriptionValueCount: missingDescriptionValueCount,
            invalidValueCount: invalidValueCount,
            conflictingPowerValueCount: conflictingPowerValueCount
        )
    }

    /// Decode one captured payload into its physical value, applying the
    /// description's base type (with per-type invalid sentinels) and its
    /// scale/offset. Returns nil for invalid sentinels, non-numeric types,
    /// and non-finite results.
    ///
    /// Offset is **subtracted**. Derived from the official Garmin SDKs whose
    /// bindings this codebase resembles (see AGENTS.md "FIT reference
    /// implementations"), in order of authority:
    ///
    /// 1. **C++ SDK** — the sign, for fields it scales at all, is subtract:
    ///    `fit_field_base.cpp:440`
    ///    `return float64Value / GetScale(subFieldIndex) - GetOffset(subFieldIndex);`
    ///    (inverse, `:974`: `(value + GetOffset(...)) * GetScale(...)`).
    /// 2. **Swift SDK** — agrees exactly: `FieldBase.swift:99`
    ///    `value = Float64(fitValue: value) / scale - offset`.
    ///
    /// No official binding implements `raw / scale + offset`; that was the
    /// rejected alternative, and it decodes a non-zero-offset field wrong by
    /// exactly `2 * offset`.
    ///
    /// The two SDKs DO disagree on a separate question — whether developer
    /// fields are scaled at all — and that disagreement is reported, not
    /// resolved, here:
    ///  - C++ declines. `fit_developer_field.cpp:100-110` hard-codes
    ///    `GetScale()` to `1.0` and `GetOffset()` to `0`, commented
    ///    "Developer fields do not currently support scale/offset".
    ///  - Swift applies. `DeveloperField.swift:54-60` returns
    ///    `fieldDescriptionMesg?.getScale() ?? 1` and `...getOffset() ?? 0`,
    ///    feeding the description's values into the subtract above.
    ///  - The C SDK abstains: it decodes no developer fields at all.
    ///
    /// This importer applies the conversion, matching the Swift SDK — the
    /// binding closest to RunPlayCore's decoding. Because that choice is
    /// contested, every non-zero offset is surfaced in the import report
    /// (`WorkoutDeveloperFieldSummary`): a non-zero offset is precisely the
    /// case where the two bindings would report different numbers.
    static func physicalValue(
        of raw: FITRecordDeveloperFieldValue,
        description: FITFieldDescriptionMessage
    ) -> Double? {
        guard let baseType = description.baseType else { return nil }
        guard !raw.bytes.isEmpty else { return nil }
        var reader = FITBinaryReader(
            data: raw.bytes,
            offset: 0,
            endOffset: raw.bytes.count,
            littleEndian: raw.littleEndian
        )
        guard let firstValue = try? reader.readBaseTypeArray(
            baseType: baseType,
            fieldSize: raw.bytes.count
        ).first,
            let numeric = firstValue.numericValue
        else {
            return nil
        }
        let physical = numeric / description.effectiveScale
            - description.effectiveOffset
        return physical.isFinite ? physical : nil
    }

    private static func descriptionKey(
        developerDataIndex: UInt8,
        fieldNumber: UInt8
    ) -> UInt16 {
        (UInt16(developerDataIndex) << 8) | UInt16(fieldNumber)
    }

    private struct FieldStatAccumulator {
        let developerDataIndex: UInt8
        let fieldNumber: UInt8
        let fieldName: String
        let unit: String?
        let baseTypeName: String
        let scale: Double
        let offset: Double
        let metric: FITDeveloperMetric?
        let declaresAccumulation: Bool

        private var sampleCount = 0
        private var minimum: Double?
        private var maximum: Double?
        private var total = 0.0

        init(description: FITFieldDescriptionMessage) {
            developerDataIndex = description.developerDataIndex ?? 0
            fieldNumber = description.fieldDefinitionNumber ?? 0
            fieldName = description.fieldName ?? ""
            unit = description.resolvedUnit
            baseTypeName = description.baseType.map {
                String(describing: $0)
            } ?? "unknown"
            scale = description.effectiveScale
            offset = description.effectiveOffset
            metric = FITDeveloperMetric.match(fieldName: fieldName)
            declaresAccumulation = description.declaresAccumulation
        }

        mutating func add(_ value: Double) {
            sampleCount += 1
            total += value
            if let currentMin = minimum {
                minimum = min(currentMin, value)
            } else {
                minimum = value
            }
            if let currentMax = maximum {
                maximum = max(currentMax, value)
            } else {
                maximum = value
            }
        }

        func finalize() -> FITDeveloperFieldReport.FieldStat {
            FITDeveloperFieldReport.FieldStat(
                developerDataIndex: developerDataIndex,
                fieldNumber: fieldNumber,
                fieldName: fieldName,
                unit: unit,
                baseTypeName: baseTypeName,
                scale: scale,
                offset: offset,
                metric: metric,
                sampleCount: sampleCount,
                minimum: minimum,
                maximum: maximum,
                mean: sampleCount > 0 ? total / Double(sampleCount) : nil,
                declaresAccumulation: declaresAccumulation
            )
        }
    }
}

// MARK: - Decode Report

/// File-level developer data context threaded into session record decoding.
struct FITDeveloperDataContext: Sendable {
    let descriptions: [FITFieldDescriptionMessage]
    let identities: [FITDeveloperDataIDMessage]
    var droppedValueCount: Int
    var droppedDescriptionCount: Int

    init(decodedFile: FITDecodedFile) {
        descriptions = decodedFile.fieldDescriptions
        identities = decodedFile.developerDataIDs
        droppedValueCount = decodedFile.droppedDeveloperFieldValueCount
        droppedDescriptionCount = decodedFile.droppedFieldDescriptionCount
    }
}

/// File-level outcome of developer data decoding for one decoded session,
/// carried on `FITDecodedRouteResult` for the importer to persist.
public struct FITDeveloperFieldReport: Sendable, Equatable {
    public struct Source: Sendable, Equatable {
        public let developerDataIndex: UInt8
        public let developerIDHex: String?
        public let applicationIDHex: String?
        public let manufacturerID: UInt16?
        public let applicationVersion: UInt32?

        init(
            developerDataIndex: UInt8,
            developerIDHex: String?,
            applicationIDHex: String?,
            manufacturerID: UInt16?,
            applicationVersion: UInt32?
        ) {
            self.developerDataIndex = developerDataIndex
            self.developerIDHex = developerIDHex
            self.applicationIDHex = applicationIDHex
            self.manufacturerID = manufacturerID
            self.applicationVersion = applicationVersion
        }
    }

    public struct FieldStat: Sendable, Equatable {
        public let developerDataIndex: UInt8
        public let fieldNumber: UInt8
        public let fieldName: String
        public let unit: String?
        public let baseTypeName: String
        public let scale: Double
        public let offset: Double
        public let metric: FITDeveloperMetric?
        public let sampleCount: Int
        public let minimum: Double?
        public let maximum: Double?
        public let mean: Double?
        public let declaresAccumulation: Bool
    }

    public var sources: [Source]
    public var fieldStats: [FieldStat]
    /// Retained route points the stats' coverage is relative to.
    public var totalPointCount: Int
    public var missingDescriptionValueCount: Int
    public var invalidValueCount: Int
    public var conflictingPowerValueCount: Int
    /// Values the parser dropped before resolution (retention budget).
    public var droppedValueCount: Int
    /// Descriptions the parser dropped (bounded description table).
    public var droppedDescriptionCount: Int
    /// Points whose power came from the native record field 7.
    public var nativeRecordPowerPointCount: Int
    /// Points whose power came from a recognized developer field.
    public var developerPowerPointCount: Int
    /// Developer data index that supplied power, when a developer field did.
    public var powerDeveloperDataIndex: UInt8?
    /// Points where a native running-dynamics record field (39/41/83/84/85)
    /// supplied a value the developer path had not.
    public var nativeRecordDynamicsPointCount: Int
    /// Points where a recognized developer field supplied any
    /// running-dynamics value.
    public var developerDynamicsPointCount: Int

    init(
        sources: [Source] = [],
        fieldStats: [FieldStat] = [],
        totalPointCount: Int = 0,
        missingDescriptionValueCount: Int = 0,
        invalidValueCount: Int = 0,
        conflictingPowerValueCount: Int = 0,
        droppedValueCount: Int = 0,
        droppedDescriptionCount: Int = 0,
        nativeRecordPowerPointCount: Int = 0,
        developerPowerPointCount: Int = 0,
        powerDeveloperDataIndex: UInt8? = nil,
        nativeRecordDynamicsPointCount: Int = 0,
        developerDynamicsPointCount: Int = 0
    ) {
        self.sources = sources
        self.fieldStats = fieldStats
        self.totalPointCount = totalPointCount
        self.missingDescriptionValueCount = missingDescriptionValueCount
        self.invalidValueCount = invalidValueCount
        self.conflictingPowerValueCount = conflictingPowerValueCount
        self.droppedValueCount = droppedValueCount
        self.droppedDescriptionCount = droppedDescriptionCount
        self.nativeRecordPowerPointCount = nativeRecordPowerPointCount
        self.developerPowerPointCount = developerPowerPointCount
        self.powerDeveloperDataIndex = powerDeveloperDataIndex
        self.nativeRecordDynamicsPointCount = nativeRecordDynamicsPointCount
        self.developerDynamicsPointCount = developerDynamicsPointCount
    }

    public static let empty = FITDeveloperFieldReport()

    public var isEmpty: Bool {
        fieldStats.isEmpty
            && sources.isEmpty
            && missingDescriptionValueCount == 0
            && invalidValueCount == 0
            && droppedValueCount == 0
            && droppedDescriptionCount == 0
            && nativeRecordPowerPointCount == 0
            && developerPowerPointCount == 0
            && nativeRecordDynamicsPointCount == 0
            && developerDynamicsPointCount == 0
    }
}

/// Hex rendering for developer GUID payloads: stable, lowercase, no dashes.
extension Data {
    var fitDeveloperHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
