import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Errors raised while streaming an Apple Health `export.xml`.
public enum AppleHealthExportError: Error, Equatable, LocalizedError, Sendable {

    /// The DTD carried a construct that could supply a value, so eliding it
    /// would have silently dropped data.
    ///
    /// Carries the violation's message rather than the `DTDPolicyViolation`
    /// itself, because that type is internal to this module and a public error
    /// case cannot expose it. Nothing is lost: the message is what an import
    /// failure surfaces, and which construct was found is already covered
    /// exhaustively by `DTDValueSupplyingScannerTests`.
    ///
    /// Raised here rather than by `XMLParser` because the parser cannot see it —
    /// by the time it runs, the DTD has already been removed, so it would report
    /// a truncated-document error that says nothing about the real cause.
    case dtdSuppliesValue(String)

    /// `XMLParser` reported a failure and no more specific cause was known.
    case malformedDocument(String)

    /// The export contained no `HealthData` root element, so it is not the
    /// document this parser reads.
    case notAHealthExport

    /// The heart-rate index reached `AppleHealthHeartRateIndex.maximumSampleCount`
    /// and the source could not be read a second time.
    ///
    /// Raised only by `parse(stream:)`, which has no way to reopen a consumed
    /// stream. `parse(openStream:)` handles this itself by running the filtered
    /// second pass, so a caller that can reopen the document never sees it.
    case heartRateIndexNeedsSecondPass

    /// The heart-rate index reached its ceiling on *both* passes.
    ///
    /// Means the workout windows between them are so wide that filtered
    /// retention is no smaller than whole-life retention, so no bounded pass can
    /// succeed and this is a refusal rather than another retry.
    ///
    /// `ceiling` is the value actually enforced, not necessarily
    /// `AppleHealthHeartRateIndex.maximumSampleCount`: the ceiling is injectable
    /// so tests can reach the two-pass fallback, and reporting the static
    /// constant from such a run would state a number the import never used.
    case heartRateCeilingExceededEvenWhenFiltered(ceiling: Int)

    public var errorDescription: String? {
        switch self {
        case .dtdSuppliesValue(let message):
            return message
        case .malformedDocument(let detail):
            return "This Apple Health export could not be read. \(detail)"
        case .notAHealthExport:
            return "This file is not an Apple Health export. "
                + "Export your data from the Health app and try again."
        case .heartRateIndexNeedsSecondPass:
            return "This Apple Health export has more heart-rate history than "
                + "RunPlay Studio indexes in one pass, and this source cannot be "
                + "read twice. It was not imported."
        case .heartRateCeilingExceededEvenWhenFiltered(let ceiling):
            return "This Apple Health export has too much heart-rate history "
                + "inside its workout windows to import (more than \(ceiling) "
                + "samples). It was not imported."
        }
    }
}

/// What one streaming pass over `export.xml` produced.
///
/// Deliberately not a `RunWorkout`: turning a window plus its joined heart rate
/// plus the workout's linked route GPX into a workout is a later layer's
/// decision, and this type is the raw material for it. Keeping the scan separate
/// from workout construction is what lets the scan be tested on Linux against
/// generated documents with no fixture files on disk.
public struct AppleHealthExportScan: Sendable {

    /// One `Workout` element, with everything the scan could attribute to it.
    public struct WorkoutEntry: Sendable {

        /// The workout's own reported window.
        public var window: AppleHealthWorkoutWindow

        /// `WorkoutStatistics` rows belonging to this workout, keyed by nothing —
        /// carried verbatim so the layer that decides what a summary is can read
        /// `type`, `sum`, `average`, `minimum`, `maximum` and `unit` itself.
        public var statistics: [AppleHealthWorkoutStatistic]

        /// Archive-relative path from this workout's `FileReference`, if any.
        ///
        /// Already resolved to the form the archive actually stores: the export
        /// writes `/workout-routes/route_….gpx` (leading slash, no
        /// `apple_health_export` prefix) while the entry is at
        /// `apple_health_export/workout-routes/route_….gpx`. Measured over all
        /// 738 references, prefixing `apple_health_export/` resolves every one
        /// with zero dangling, so the rule is applied here rather than left to
        /// each caller.
        ///
        /// A path is **not** a workout identity: one of the 738 is shared by two
        /// workouts, so it must never be used as a key.
        public var routeArchivePath: String?

        /// Heart rate joined to this workout by time overlap.
        ///
        /// Empty when the export carries no heart rate for the window — which is
        /// the common case for older workouts, since the measured export's
        /// heart-rate history spans 799 days against a workout history of 2,184,
        /// and 9.3% of its running workouts have none.
        ///
        /// This is the only heart rate the scan publishes. The whole-life index
        /// that made the join possible is released when the pass ends, so a
        /// caller cannot reach a reading outside some workout's window.
        public var heartRate: [AppleHealthHeartRateReading]

        public init(
            window: AppleHealthWorkoutWindow,
            statistics: [AppleHealthWorkoutStatistic] = [],
            routeArchivePath: String? = nil,
            heartRate: [AppleHealthHeartRateReading] = []
        ) {
            self.window = window
            self.statistics = statistics
            self.routeArchivePath = routeArchivePath
            self.heartRate = heartRate
        }
    }

    /// `locale` from the `HealthData` root element.
    public var locale: String?

    /// `value` from the single `ExportDate` element, if the export has one.
    public var exportDate: Date?

    /// Every `Workout` element, in document order.
    ///
    /// Document order is chronological in the measured export (all 1,444
    /// `Workout@startDate` values are non-decreasing), but nothing here depends
    /// on that.
    public var workouts: [WorkoutEntry]

    /// How many forward passes the scan needed.
    ///
    /// One whenever the heart-rate index fit inside its ceiling, which is the
    /// designed path; two when the ceiling forced the filtered fallback.
    /// Recorded because the cost difference is a read of the whole document and
    /// a caller is entitled to know which happened.
    public var passCount: Int

    /// Heart-rate `Record` elements the scan saw, before any filtering.
    public var heartRateRecordCount: Int

    /// `Record` elements skipped because they were nested inside a `Workout`.
    ///
    /// Counted rather than silently ignored: the measured export has 282 of
    /// them, and a parser that tracked no nesting would index those as
    /// heart-rate history. A nonzero count here proves the depth tracking ran.
    public var nestedRecordCount: Int

    /// True when the first pass exceeded the ceiling and a second pass ran.
    public var usedFilteredSecondPass: Bool { passCount > 1 }

    public init(
        locale: String? = nil,
        exportDate: Date? = nil,
        workouts: [WorkoutEntry] = [],
        passCount: Int = 1,
        heartRateRecordCount: Int = 0,
        nestedRecordCount: Int = 0
    ) {
        self.locale = locale
        self.exportDate = exportDate
        self.workouts = workouts
        self.passCount = passCount
        self.heartRateRecordCount = heartRateRecordCount
        self.nestedRecordCount = nestedRecordCount
    }
}

/// One `WorkoutStatistics` row, verbatim.
public struct AppleHealthWorkoutStatistic: Equatable, Hashable, Sendable {

    /// `type`, for example `HKQuantityTypeIdentifierDistanceWalkingRunning`.
    public var type: String
    /// `unit`, for example `km` or `count/min`. Absent on some rows: the DTD
    /// declares it `#IMPLIED` and 79,309 `Record` elements in the measured
    /// export omit it.
    public var unit: String?
    /// `sum`, when present. Distance and energy arrive this way.
    public var sum: Double?
    /// `average`, when present. Heart rate and speed arrive this way.
    public var average: Double?
    /// `minimum`, when present.
    public var minimum: Double?
    /// `maximum`, when present.
    public var maximum: Double?

    public init(
        type: String,
        unit: String? = nil,
        sum: Double? = nil,
        average: Double? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.type = type
        self.unit = unit
        self.sum = sum
        self.average = average
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Streaming reader for Apple Health's `export.xml`.
///
/// ## What it does
///
/// One forward pass over a document that is 1.36 GB uncompressed in the measured
/// export, retaining the heart-rate index and the workout windows while holding
/// nothing else. Never materializes the document: `XMLParser(stream:)` pulls
/// through `DTDStrippingInputStream`, whose bulk passthrough means the elider
/// adds no per-byte cost once the DTD is behind it. Measured, `XMLParser`
/// sustains 167,434 elements per second, so the real export's 5.14M elements
/// parse in about 31 seconds — the parser is not the bottleneck and no
/// hand-rolled scanner is warranted.
///
/// The DTD is elided because it has to be: Foundation's `XMLParser` segfaults on
/// Linux when a document's inline DTD contains an `ATTLIST` with a default
/// keyword, which this export's 23 `ATTLIST` declarations do. See
/// `DTDStrippingInputStream` and
/// <https://github.com/swiftlang/swift-corelibs-foundation/issues/5573>.
///
/// ## Why one pass usually suffices
///
/// Every heart-rate record precedes every `Workout` element, so the readings can
/// be accumulated and sorted before the first window needs them. The readings
/// are **not** chronological in document order (84.5% are displaced from their
/// final sorted position), which rules out a merge join and makes the buffer
/// mandatory rather than an optimization.
///
/// When the buffer would exceed its ceiling the scan runs a second pass keeping
/// only in-window readings. See `AppleHealthHeartRateIndex` for the sizing.
///
/// ## Cancellation
///
/// Checked cooperatively around the native parse call and while translating
/// results, never inside it — the same shape every other importer in this
/// package uses.
public struct AppleHealthExportParser: Sendable {

    /// Element and attribute names in the export's own vocabulary.
    ///
    /// Named once here so a misspelling is one diff rather than a silent
    /// zero-count scan.
    enum Element {
        static let healthData = "HealthData"
        static let exportDate = "ExportDate"
        static let record = "Record"
        static let workout = "Workout"
        static let workoutStatistics = "WorkoutStatistics"
        static let workoutRoute = "WorkoutRoute"
        static let fileReference = "FileReference"
    }

    enum Attribute {
        static let locale = "locale"
        static let type = "type"
        static let unit = "unit"
        static let value = "value"
        static let startDate = "startDate"
        static let endDate = "endDate"
        static let workoutActivityType = "workoutActivityType"
        static let path = "path"
        static let sum = "sum"
        static let average = "average"
        static let minimum = "minimum"
        static let maximum = "maximum"
    }

    /// The heart-rate quantity type. The only `Record` type indexed.
    ///
    /// `HKQuantityTypeIdentifierRestingHeartRate` (1,449 in the measured
    /// export) and `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` (8,756,
    /// with 511,320 nested `InstantaneousBeatsPerMinute` children) are distinct
    /// quantities that must not be mistaken for workout heart rate.
    static let heartRateType = "HKQuantityTypeIdentifierHeartRate"

    /// Directory prefix the export's own `FileReference@path` omits.
    static let archiveRoot = "apple_health_export"

    /// Ceiling passed to each `AppleHealthHeartRateIndex` this parser builds.
    ///
    /// Injectable for the same reason as on the index itself: the two-pass
    /// fallback only runs when the ceiling is reached, and at the production
    /// ceiling of 2,000,000 no test could reach it. Tests lower this so the
    /// fallback executes through the real production path end to end, rather than
    /// being verified against a separate small-scale implementation that could
    /// drift from the shipped one.
    private let heartRateCeiling: Int

    /// Production entry point: parses at the index's own production ceiling.
    public init() {
        self.init(heartRateCeiling: AppleHealthHeartRateIndex.maximumSampleCount)
    }

    /// Test seam for the ceiling.
    ///
    /// Internal rather than a defaulted public argument: the ceiling constant
    /// lives on an internal type, and a default argument is part of the public
    /// interface — it is inlined at the call site, so it may not name an
    /// internal symbol. Keeping the seam internal also keeps the choice of
    /// ceiling out of the product API, where no caller should be making it.
    init(heartRateCeiling: Int) {
        self.heartRateCeiling = heartRateCeiling
    }

    /// Parse `export.xml`, opening the document through `openStream`.
    ///
    /// ## Why a factory and not a stream
    ///
    /// The two-pass fallback has to read the document **twice**, and a consumed
    /// `InputStream` cannot be rewound — so a parser handed one open stream
    /// could detect the ceiling and then be unable to act on it. Taking a
    /// factory lets this parser own the second pass entirely, which is what makes
    /// the fallback real rather than advisory.
    ///
    /// A caller with only a single non-reopenable source passes a factory that
    /// returns it once and throws on any second call; such a caller then gets
    /// `.heartRateIndexNeedsSecondPass` instead of a silently wrong result.
    ///
    /// ## Why not a URL
    ///
    /// Reading `export.zip` is `RunPlayPlatform`'s job: `Package.swift` confines
    /// ZIP access to that target and forbids it in `RunPlayCore`. Accepting a
    /// factory also keeps every test here executable on Linux against a generated
    /// document, with no fixture files and no ZIP reader involved.
    ///
    /// Each stream is wrapped in `DTDStrippingInputStream` unless `elideDTD` is
    /// false. `policyViolation` is checked before `XMLParser`'s own error is
    /// trusted, because after a violation the parser sees a truncated document
    /// and would report a misleading failure.
    public func parse(
        openStream: () throws -> InputStream,
        elideDTD: Bool = true,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> AppleHealthExportScan {
        let first = try runPass(
            openStream: openStream,
            elideDTD: elideDTD,
            windowFilter: nil,
            isCancelled: isCancelled
        )

        guard first.releasedByCeiling else {
            return first.scan
        }

        // The whole-life index did not fit. Re-scan keeping only readings that
        // overlap a workout window, which the first pass has already collected —
        // that is what makes pass two cheaper in memory rather than merely
        // slower. Measured on the real export: 65,828 of 871,413 readings
        // (7.6%) land inside a window, about 1.6 MB against 48 MB.
        let windows = first.scan.workouts.map(\.window)
        let second = try runPass(
            openStream: openStream,
            elideDTD: elideDTD,
            windowFilter: windows,
            isCancelled: isCancelled
        )

        guard !second.releasedByCeiling else {
            // Even filtered retention exceeded the ceiling, so no bounded pass
            // can succeed. This is a refusal, not another retry.
            throw AppleHealthExportError.heartRateCeilingExceededEvenWhenFiltered(
                ceiling: heartRateCeiling
            )
        }

        var scan = second.scan
        scan.passCount = 2
        return scan
    }

    /// Parse a single non-reopenable stream.
    ///
    /// Convenience over `parse(openStream:)` for the common case. Throws
    /// `.heartRateIndexNeedsSecondPass` if the ceiling is reached, because this
    /// entry point has no way to read the document again.
    public func parse(
        stream: InputStream,
        elideDTD: Bool = true,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> AppleHealthExportScan {
        var isOpen = true
        return try parse(
            openStream: {
                guard isOpen else {
                    throw AppleHealthExportError.heartRateIndexNeedsSecondPass
                }
                isOpen = false
                return stream
            },
            elideDTD: elideDTD,
            isCancelled: isCancelled
        )
    }

    /// Run one forward pass, optionally restricted to readings inside `windowFilter`.
    private func runPass(
        openStream: () throws -> InputStream,
        elideDTD: Bool,
        windowFilter: [AppleHealthWorkoutWindow]?,
        isCancelled: @Sendable () -> Bool
    ) throws -> PassResult {
        guard !isCancelled() else { throw CancellationError() }

        let source = try openStream()
        let input: InputStream
        let elider: DTDStrippingInputStream?
        if elideDTD {
            let stripper = DTDStrippingInputStream(upstream: source)
            input = stripper
            elider = stripper
        } else {
            input = source
            elider = nil
        }

        let delegate = Delegate(
            windowFilter: windowFilter,
            heartRateCeiling: heartRateCeiling
        )

        let parser = XMLParser(stream: input)
        parser.delegate = delegate
        // Matches GPXImporter and TCXImporter: no namespace handling, and no
        // external entity resolution. The export declares no namespace on
        // HealthData, and resolving entities would be both a network hazard and
        // a billion-laughs hazard.
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let parsed = parser.parse()

        guard !isCancelled() else { throw CancellationError() }

        // Check the elider's verdict before the parser's. After a policy
        // violation the elider stops feeding bytes, so the parser reports a
        // truncated-document error that says nothing about the real cause.
        if let violation = elider?.policyViolation {
            throw AppleHealthExportError.dtdSuppliesValue(violation.description)
        }

        guard parsed else {
            let detail = parser.parserError.map { $0.localizedDescription }
                ?? "The document ended unexpectedly."
            throw AppleHealthExportError.malformedDocument(detail)
        }

        guard delegate.sawHealthData else {
            throw AppleHealthExportError.notAHealthExport
        }

        let lookup = delegate.finalizeIndex()
        return PassResult(
            scan: delegate.buildScan(lookup: lookup),
            releasedByCeiling: delegate.releasedByCeiling
        )
    }

    private struct PassResult {
        let scan: AppleHealthExportScan
        let releasedByCeiling: Bool
    }
}

/// The `XMLParserDelegate` that does the actual scanning.
///
/// A class because `XMLParser` holds its delegate weakly and because the
/// delegate mutates during the parse while the caller keeps the only strong
/// reference. Not part of the public API.
private final class Delegate: NSObject, XMLParserDelegate {

    private var index: AppleHealthHeartRateIndex

    private var locale: String?
    private var exportDate: Date?
    /// Internal, not private: `AppleHealthExportParser.runPass` reads it after
    /// the parse to tell a health export from some other well-formed document.
    /// `Delegate` is itself file-private, so this widens nothing outside the file.
    var sawHealthData = false

    /// Open `Workout` elements only.
    ///
    /// Counting Workout depth alone is sufficient and is the part worth being
    /// careful about: a `Record` can never contain a `Workout`, so the 1,440,512
    /// non-self-closing top-level `Record` elements — which do have closing tags
    /// and would otherwise have to be tracked — cannot affect the decision. The
    /// measured export nests 282 `Record` elements inside workouts, and a
    /// depth-blind parser would index those as heart-rate history.
    private var workoutDepth = 0

    private var pendingWorkouts: [AppleHealthExportScan.WorkoutEntry] = []
    private var currentWorkout: AppleHealthExportScan.WorkoutEntry?
    private var currentRoutePath: String?

    private var heartRateRecordCount = 0
    private var nestedRecordCount = 0

    init(windowFilter: [AppleHealthWorkoutWindow]?, heartRateCeiling: Int) {
        index = AppleHealthHeartRateIndex(sampleCountCeiling: heartRateCeiling)
        super.init()
        if let windows = windowFilter {
            // A second pass restricts retention to readings that overlap a
            // window, which is what makes it cheaper in memory than the first
            // rather than merely slower. An empty window list retains nothing:
            // with no workouts there is no heart rate to join, so an empty index
            // is the correct answer rather than a failure.
            index.beginFilteredPass(windows: windows)
        }
    }

    var releasedByCeiling: Bool { index.releasedByCeiling }

    func finalizeIndex() -> AppleHealthHeartRateLookup {
        index.finalize()
    }

    func buildScan(lookup: AppleHealthHeartRateLookup) -> AppleHealthExportScan {
        var workouts = pendingWorkouts
        if let current = currentWorkout {
            workouts.append(current)
        }

        // Join heart rate to each workout by time overlap. Done here rather than
        // during the parse because the index is not sortable until the pass ends,
        // and a range query over unsorted readings would silently miss some.
        for position in workouts.indices {
            let window = workouts[position].window
            workouts[position].heartRate = lookup.readings(in: window)
        }

        return AppleHealthExportScan(
            locale: locale,
            exportDate: exportDate,
            workouts: workouts,
            passCount: 1,
            heartRateRecordCount: heartRateRecordCount,
            nestedRecordCount: nestedRecordCount
        )
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case AppleHealthExportParser.Element.healthData:
            sawHealthData = true
            locale = attributeDict[AppleHealthExportParser.Attribute.locale]

        case AppleHealthExportParser.Element.exportDate:
            // Only the first ExportDate counts; the export has exactly one.
            if exportDate == nil,
               let raw = attributeDict[AppleHealthExportParser.Attribute.value] {
                exportDate = Self.date(from: raw)
            }

        case AppleHealthExportParser.Element.workout:
            workoutDepth += 1
            if workoutDepth == 1 {
                flushPendingWorkout()
                if let window = Self.window(
                    from: attributeDict,
                    typeKey: AppleHealthExportParser.Attribute.workoutActivityType
                ) {
                    currentWorkout = AppleHealthExportScan.WorkoutEntry(window: window)
                    currentRoutePath = nil
                }
            }

        case AppleHealthExportParser.Element.workoutStatistics:
            if workoutDepth >= 1, var workout = currentWorkout {
                workout.statistics.append(Self.statistic(from: attributeDict))
                currentWorkout = workout
            }

        case AppleHealthExportParser.Element.fileReference:
            // FileReference is a child of WorkoutRoute, which is a child of
            // Workout. Only the first per workout is kept: no workout in the
            // measured export has more than one route, and a path is not an
            // identity anyway.
            if workoutDepth >= 1, currentWorkout != nil, currentRoutePath == nil,
               let path = attributeDict[AppleHealthExportParser.Attribute.path] {
                currentRoutePath = Self.resolveArchivePath(path)
            }

        case AppleHealthExportParser.Element.record:
            if workoutDepth >= 1 {
                nestedRecordCount += 1
                return
            }
            guard attributeDict[AppleHealthExportParser.Attribute.type]
                == AppleHealthExportParser.heartRateType else { return }
            heartRateRecordCount += 1
            guard let reading = Self.reading(from: attributeDict) else { return }
            index.append(reading)

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case AppleHealthExportParser.Element.workout:
            if workoutDepth > 0 { workoutDepth -= 1 }
            if workoutDepth == 0 { flushPendingWorkout() }

        default:
            break
        }
    }

    /// Move the in-progress workout into the completed list, attaching its route.
    private func flushPendingWorkout() {
        guard var workout = currentWorkout else { return }
        workout.routeArchivePath = currentRoutePath
        pendingWorkouts.append(workout)
        currentWorkout = nil
        currentRoutePath = nil
    }

    // MARK: - Attribute translation

    private static func window(
        from attributeDict: [String: String],
        typeKey: String
    ) -> AppleHealthWorkoutWindow? {
        guard let startRaw = attributeDict[AppleHealthExportParser.Attribute.startDate],
              let endRaw = attributeDict[AppleHealthExportParser.Attribute.endDate],
              let startParsed = AppleHealthDateParser.parse(startRaw),
              let end = seconds(from: endRaw) else { return nil }
        let start = Int64(startParsed.date.timeIntervalSince1970.rounded(.down))
        // A reversed window is not rejected outright: clamping keeps the workout
        // visible to later layers, which can then report the anomaly instead of
        // silently dropping a workout the user can see in Health. The offset
        // stays the one written on the start, which is what trends buckets by.
        return AppleHealthWorkoutWindow(
            startSeconds: min(start, end),
            endSeconds: max(start, end),
            activityType: attributeDict[typeKey] ?? "",
            utcOffsetSeconds: startParsed.utcOffsetSeconds
        )
    }

    private static func reading(
        from attributeDict: [String: String]
    ) -> AppleHealthHeartRateReading? {
        guard let startRaw = attributeDict[AppleHealthExportParser.Attribute.startDate],
              let start = seconds(from: startRaw) else { return nil }

        var duration: UInt32 = 0
        if let endRaw = attributeDict[AppleHealthExportParser.Attribute.endDate],
           let end = seconds(from: endRaw), end > start {
            let span = end - start
            // Saturate into the stored width rather than wrapping, so a hostile
            // or corrupt duration cannot produce a reading whose end precedes
            // its start and make it unqueryable.
            duration = span > Int64(UInt32.max) ? UInt32.max : UInt32(truncatingIfNeeded: span)
        }

        // A missing or unparseable value still yields a reading, with nil bpm
        // upstream — but this type has no nil bpm, so such records are dropped
        // here. Dropping is right: an HR record with no bpm contributes nothing
        // to a series, and inventing one would corrupt training load.
        guard let valueRaw = attributeDict[AppleHealthExportParser.Attribute.value],
              let bpm = Double(valueRaw), bpm.isFinite else { return nil }

        return AppleHealthHeartRateReading(
            startSeconds: start,
            durationSeconds: duration,
            beatsPerMinute: bpm
        )
    }

    private static func statistic(
        from attributeDict: [String: String]
    ) -> AppleHealthWorkoutStatistic {
        AppleHealthWorkoutStatistic(
            type: attributeDict[AppleHealthExportParser.Attribute.type] ?? "",
            unit: attributeDict[AppleHealthExportParser.Attribute.unit],
            sum: numeric(attributeDict[AppleHealthExportParser.Attribute.sum]),
            average: numeric(attributeDict[AppleHealthExportParser.Attribute.average]),
            minimum: numeric(attributeDict[AppleHealthExportParser.Attribute.minimum]),
            maximum: numeric(attributeDict[AppleHealthExportParser.Attribute.maximum])
        )
    }

    private static func numeric(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    /// Whole UTC seconds for a fixed-width Apple Health timestamp.
    private static func seconds(from raw: String) -> Int64? {
        guard let parsed = AppleHealthDateParser.parse(raw) else { return nil }
        return Int64(parsed.date.timeIntervalSince1970.rounded(.down))
    }

    private static func date(from raw: String) -> Date? {
        AppleHealthDateParser.parse(raw)?.date
    }

    /// Turn the export's `FileReference@path` into an archive entry path.
    ///
    /// The export writes `/workout-routes/route_….gpx` — a leading slash and no
    /// `apple_health_export` prefix — while the archive stores
    /// `apple_health_export/workout-routes/route_….gpx`. Measured over all 738
    /// references: zero contain `..`, all 738 end in `.gpx`, all 738 start with
    /// a slash, and prefixing `apple_health_export/` resolves all 738 with zero
    /// dangling. So the leading slash is collapsed and the prefix added.
    ///
    /// A path that escapes the archive root (`..`) is rejected rather than
    /// normalized, because it would be a traversal out of the user's own export.
    private static func resolveArchivePath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains("..") else { return nil }

        var components: [String] = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return nil }
        if components[0] == AppleHealthExportParser.archiveRoot {
            components.removeFirst()
        }
        guard !components.isEmpty else { return nil }
        components.insert(AppleHealthExportParser.archiveRoot, at: 0)
        return components.joined(separator: "/")
    }
}
