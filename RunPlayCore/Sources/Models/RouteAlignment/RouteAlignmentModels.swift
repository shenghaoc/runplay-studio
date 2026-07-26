import Foundation

// MARK: - Quality / availability

/// Product-facing quality when Route-Aware alignment is available.
public enum RouteAlignmentQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case excellent
    case good
    case limited

    public var displayName: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .limited: return "Limited"
        }
    }
}

/// Structured reasons Route-Aware alignment cannot be used.
public enum RouteAlignmentUnavailableReason: String, CaseIterable, Codable, Hashable, Sendable {
    case insufficientRouteData
    case insufficientMatchedDistance
    case insufficientCoverage
    case routesTooFarApart
    case excessiveWarping
    case oppositeDirection
    case ambiguousGeometry
    case unsupportedGeographicExtent
    case resourceLimit
    case cancelled
    case algorithmFailure

    public var userFacingExplanation: String {
        switch self {
        case .insufficientRouteData:
            return "There is not enough continuous GPS route data for route-aware comparison."
        case .insufficientMatchedDistance:
            return "Only a short fragment of the routes could be matched reliably."
        case .insufficientCoverage:
            return "Only a limited portion of the routes could be matched reliably."
        case .routesTooFarApart:
            return "The routes are too far apart for route-aware comparison."
        case .excessiveWarping:
            return "Route correspondence requires too much stretching to be reliable."
        case .oppositeDirection:
            return "Routes appear to be travelled in opposite directions."
        case .ambiguousGeometry:
            return "These loop recordings begin too far apart for this alignment mode."
        case .unsupportedGeographicExtent:
            return "The geographic extent of these routes is too large for local alignment."
        case .resourceLimit:
            return "These routes are too large for route-aware comparison with the current budget."
        case .cancelled:
            return "Route alignment was cancelled."
        case .algorithmFailure:
            return "Route alignment could not be completed."
        }
    }
}

/// Whether Route-Aware alignment can be used and at what quality.
public enum RouteAlignmentAvailability: Hashable, Sendable {
    case available(RouteAlignmentQuality)
    case unavailable(RouteAlignmentUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var quality: RouteAlignmentQuality? {
        if case .available(let quality) = self { return quality }
        return nil
    }

    public var unavailableReason: RouteAlignmentUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Coarse direction estimate used for availability.
public enum RouteAlignmentDirection: String, CaseIterable, Codable, Hashable, Sendable {
    case same
    case opposite
    case ambiguous
    case unknown
}

// MARK: - Anchors / blocks / snapshot

/// One matched primary/comparison sample pair along aligned progress.
public struct RouteAlignmentAnchor: Hashable, Sendable {
    public let alignedProgressMeters: Double
    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let spatialSeparationMeters: Double
    public let primarySegmentIndex: Int
    public let comparisonSegmentIndex: Int

    public init(
        alignedProgressMeters: Double,
        primaryDistanceMeters: Double,
        comparisonDistanceMeters: Double,
        spatialSeparationMeters: Double,
        primarySegmentIndex: Int,
        comparisonSegmentIndex: Int
    ) {
        self.alignedProgressMeters = Self.nonNegativeFinite(alignedProgressMeters)
        self.primaryDistanceMeters = Self.nonNegativeFinite(primaryDistanceMeters)
        self.comparisonDistanceMeters = Self.nonNegativeFinite(comparisonDistanceMeters)
        self.spatialSeparationMeters = Self.nonNegativeFinite(spatialSeparationMeters)
        self.primarySegmentIndex = max(0, primarySegmentIndex)
        self.comparisonSegmentIndex = max(0, comparisonSegmentIndex)
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// Continuous group of anchors that does not bridge a source route gap.
public struct RouteAlignmentBlock: Identifiable, Hashable, Sendable {
    public let id: Int
    public let anchors: [RouteAlignmentAnchor]
    public let alignedStartMeters: Double
    public let alignedEndMeters: Double

    public init(id: Int, anchors: [RouteAlignmentAnchor]) {
        self.id = id
        self.anchors = anchors
        self.alignedStartMeters = anchors.first?.alignedProgressMeters ?? 0
        self.alignedEndMeters = anchors.last?.alignedProgressMeters ?? self.alignedStartMeters
    }

    public var alignedDistanceMeters: Double {
        max(0, alignedEndMeters - alignedStartMeters)
    }
}

/// Diagnostics retained after DTW cost rows are released.
public struct RouteAlignmentDiagnostics: Hashable, Sendable {
    public let primaryRouteDistanceMeters: Double
    public let comparisonRouteDistanceMeters: Double
    public let primarySampleCount: Int
    public let comparisonSampleCount: Int
    public let effectiveSampleIntervalMeters: Double
    public let matchedBlockCount: Int
    public let alignedDistanceMeters: Double
    public let primaryCoverageFraction: Double
    public let comparisonCoverageFraction: Double
    public let meanSpatialSeparationMeters: Double
    public let medianSpatialSeparationMeters: Double
    public let p90SpatialSeparationMeters: Double
    public let maximumSpatialSeparationMeters: Double
    public let diagonalStepCount: Int
    public let primaryOnlyWarpStepCount: Int
    public let comparisonOnlyWarpStepCount: Int
    public let maximumConsecutiveWarpRun: Int
    public let primaryUnmatchedPrefixMeters: Double
    public let primaryUnmatchedSuffixMeters: Double
    public let comparisonUnmatchedPrefixMeters: Double
    public let comparisonUnmatchedSuffixMeters: Double
    public let detectedDirection: RouteAlignmentDirection
    public let algorithmVersion: Int
    public let warnings: [String]

    public init(
        primaryRouteDistanceMeters: Double = 0,
        comparisonRouteDistanceMeters: Double = 0,
        primarySampleCount: Int = 0,
        comparisonSampleCount: Int = 0,
        effectiveSampleIntervalMeters: Double = 0,
        matchedBlockCount: Int = 0,
        alignedDistanceMeters: Double = 0,
        primaryCoverageFraction: Double = 0,
        comparisonCoverageFraction: Double = 0,
        meanSpatialSeparationMeters: Double = 0,
        medianSpatialSeparationMeters: Double = 0,
        p90SpatialSeparationMeters: Double = 0,
        maximumSpatialSeparationMeters: Double = 0,
        diagonalStepCount: Int = 0,
        primaryOnlyWarpStepCount: Int = 0,
        comparisonOnlyWarpStepCount: Int = 0,
        maximumConsecutiveWarpRun: Int = 0,
        primaryUnmatchedPrefixMeters: Double = 0,
        primaryUnmatchedSuffixMeters: Double = 0,
        comparisonUnmatchedPrefixMeters: Double = 0,
        comparisonUnmatchedSuffixMeters: Double = 0,
        detectedDirection: RouteAlignmentDirection = .unknown,
        algorithmVersion: Int = RouteAlignmentPolicy.default.algorithmVersion,
        warnings: [String] = []
    ) {
        self.primaryRouteDistanceMeters = Self.nonNegativeFinite(primaryRouteDistanceMeters)
        self.comparisonRouteDistanceMeters = Self.nonNegativeFinite(comparisonRouteDistanceMeters)
        self.primarySampleCount = max(0, primarySampleCount)
        self.comparisonSampleCount = max(0, comparisonSampleCount)
        self.effectiveSampleIntervalMeters = Self.nonNegativeFinite(effectiveSampleIntervalMeters)
        self.matchedBlockCount = max(0, matchedBlockCount)
        self.alignedDistanceMeters = Self.nonNegativeFinite(alignedDistanceMeters)
        self.primaryCoverageFraction = Self.unitInterval(primaryCoverageFraction)
        self.comparisonCoverageFraction = Self.unitInterval(comparisonCoverageFraction)
        self.meanSpatialSeparationMeters = Self.nonNegativeFinite(meanSpatialSeparationMeters)
        self.medianSpatialSeparationMeters = Self.nonNegativeFinite(medianSpatialSeparationMeters)
        self.p90SpatialSeparationMeters = Self.nonNegativeFinite(p90SpatialSeparationMeters)
        self.maximumSpatialSeparationMeters = Self.nonNegativeFinite(maximumSpatialSeparationMeters)
        self.diagonalStepCount = max(0, diagonalStepCount)
        self.primaryOnlyWarpStepCount = max(0, primaryOnlyWarpStepCount)
        self.comparisonOnlyWarpStepCount = max(0, comparisonOnlyWarpStepCount)
        self.maximumConsecutiveWarpRun = max(0, maximumConsecutiveWarpRun)
        self.primaryUnmatchedPrefixMeters = Self.nonNegativeFinite(primaryUnmatchedPrefixMeters)
        self.primaryUnmatchedSuffixMeters = Self.nonNegativeFinite(primaryUnmatchedSuffixMeters)
        self.comparisonUnmatchedPrefixMeters = Self.nonNegativeFinite(comparisonUnmatchedPrefixMeters)
        self.comparisonUnmatchedSuffixMeters = Self.nonNegativeFinite(comparisonUnmatchedSuffixMeters)
        self.detectedDirection = detectedDirection
        self.algorithmVersion = max(0, algorithmVersion)
        self.warnings = warnings
    }

    public var compactStatusLabel: String {
        let matchedKm = alignedDistanceMeters / 1000
        let primaryPct = Int((primaryCoverageFraction * 100).rounded())
        let comparisonPct = Int((comparisonCoverageFraction * 100).rounded())
        let median = Int(medianSpatialSeparationMeters.rounded())
        return String(
            format: "%.1f km matched · %d%% / %d%% coverage · %d m median separation",
            matchedKm,
            primaryPct,
            comparisonPct,
            median
        )
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }

    private static func unitInterval(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// Immutable result of route-aware alignment.
public struct RouteAlignmentSnapshot: Hashable, Sendable {
    public let blocks: [RouteAlignmentBlock]
    public let diagnostics: RouteAlignmentDiagnostics
    public let availability: RouteAlignmentAvailability
    public let totalAlignedDistanceMeters: Double
    public let policyVersion: Int

    public init(
        blocks: [RouteAlignmentBlock],
        diagnostics: RouteAlignmentDiagnostics,
        availability: RouteAlignmentAvailability,
        policyVersion: Int = RouteAlignmentPolicy.default.algorithmVersion
    ) {
        self.blocks = blocks
        self.diagnostics = diagnostics
        self.availability = availability
        self.totalAlignedDistanceMeters = blocks.last.map(\.alignedEndMeters) ?? 0
        self.policyVersion = policyVersion
    }

    public static func unavailable(
        reason: RouteAlignmentUnavailableReason,
        diagnostics: RouteAlignmentDiagnostics = RouteAlignmentDiagnostics(),
        policyVersion: Int = RouteAlignmentPolicy.default.algorithmVersion
    ) -> RouteAlignmentSnapshot {
        RouteAlignmentSnapshot(
            blocks: [],
            diagnostics: diagnostics,
            availability: .unavailable(reason),
            policyVersion: policyVersion
        )
    }
}

// MARK: - Mapping / metrics

/// Mapped distances at one aligned-progress position.
public struct AlignedRoutePosition: Hashable, Sendable {
    public let alignedProgressMeters: Double
    public let blockIndex: Int
    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let spatialSeparationMeters: Double

    public init(
        alignedProgressMeters: Double,
        blockIndex: Int,
        primaryDistanceMeters: Double,
        comparisonDistanceMeters: Double,
        spatialSeparationMeters: Double
    ) {
        self.alignedProgressMeters = alignedProgressMeters.isFinite ? max(0, alignedProgressMeters) : 0
        self.blockIndex = max(0, blockIndex)
        self.primaryDistanceMeters = primaryDistanceMeters.isFinite ? max(0, primaryDistanceMeters) : 0
        self.comparisonDistanceMeters = comparisonDistanceMeters.isFinite ? max(0, comparisonDistanceMeters) : 0
        self.spatialSeparationMeters = spatialSeparationMeters.isFinite ? max(0, spatialSeparationMeters) : 0
    }
}

/// Matched-section clocks and pace at one aligned-progress position.
///
/// Cumulative clocks begin at the start anchor of the current alignment block
/// so unmatched prefixes do not bias elapsed/active deltas.
public struct ComparisonAlignedMetrics: Sendable {
    public let alignedProgressMeters: Double
    public let totalAlignedDistanceMeters: Double
    public let blockIndex: Int

    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let spatialSeparationMeters: Double

    public let primaryElapsedSeconds: Double?
    public let comparisonElapsedSeconds: Double?
    public let elapsedDeltaSeconds: Double?

    public let primaryActiveSeconds: Double?
    public let comparisonActiveSeconds: Double?
    public let activeDeltaSeconds: Double?

    public let primaryMovingSeconds: Double?
    public let comparisonMovingSeconds: Double?
    public let movingDeltaSeconds: Double?

    public let primaryStoppedSeconds: Double?
    public let comparisonStoppedSeconds: Double?
    public let stoppedDeltaSeconds: Double?

    public let primaryActivePaceSecondsPerKm: Double?
    public let comparisonActivePaceSecondsPerKm: Double?
    public let activePaceDeltaSecondsPerKm: Double?

    public init(
        alignedProgressMeters: Double = 0,
        totalAlignedDistanceMeters: Double = 0,
        blockIndex: Int = 0,
        primaryDistanceMeters: Double = 0,
        comparisonDistanceMeters: Double = 0,
        spatialSeparationMeters: Double = 0,
        primaryElapsedSeconds: Double? = nil,
        comparisonElapsedSeconds: Double? = nil,
        elapsedDeltaSeconds: Double? = nil,
        primaryActiveSeconds: Double? = nil,
        comparisonActiveSeconds: Double? = nil,
        activeDeltaSeconds: Double? = nil,
        primaryMovingSeconds: Double? = nil,
        comparisonMovingSeconds: Double? = nil,
        movingDeltaSeconds: Double? = nil,
        primaryStoppedSeconds: Double? = nil,
        comparisonStoppedSeconds: Double? = nil,
        stoppedDeltaSeconds: Double? = nil,
        primaryActivePaceSecondsPerKm: Double? = nil,
        comparisonActivePaceSecondsPerKm: Double? = nil,
        activePaceDeltaSecondsPerKm: Double? = nil
    ) {
        self.alignedProgressMeters = Self.nonNegativeFinite(alignedProgressMeters)
        self.totalAlignedDistanceMeters = Self.nonNegativeFinite(totalAlignedDistanceMeters)
        self.blockIndex = max(0, blockIndex)
        self.primaryDistanceMeters = Self.nonNegativeFinite(primaryDistanceMeters)
        self.comparisonDistanceMeters = Self.nonNegativeFinite(comparisonDistanceMeters)
        self.spatialSeparationMeters = Self.nonNegativeFinite(spatialSeparationMeters)
        self.primaryElapsedSeconds = Self.nonNegativeFiniteOptional(primaryElapsedSeconds)
        self.comparisonElapsedSeconds = Self.nonNegativeFiniteOptional(comparisonElapsedSeconds)
        self.elapsedDeltaSeconds = Self.finiteOptional(elapsedDeltaSeconds)
        self.primaryActiveSeconds = Self.nonNegativeFiniteOptional(primaryActiveSeconds)
        self.comparisonActiveSeconds = Self.nonNegativeFiniteOptional(comparisonActiveSeconds)
        self.activeDeltaSeconds = Self.finiteOptional(activeDeltaSeconds)
        self.primaryMovingSeconds = Self.nonNegativeFiniteOptional(primaryMovingSeconds)
        self.comparisonMovingSeconds = Self.nonNegativeFiniteOptional(comparisonMovingSeconds)
        self.movingDeltaSeconds = Self.finiteOptional(movingDeltaSeconds)
        self.primaryStoppedSeconds = Self.nonNegativeFiniteOptional(primaryStoppedSeconds)
        self.comparisonStoppedSeconds = Self.nonNegativeFiniteOptional(comparisonStoppedSeconds)
        self.stoppedDeltaSeconds = Self.finiteOptional(stoppedDeltaSeconds)
        self.primaryActivePaceSecondsPerKm = Self.positiveFiniteOptional(primaryActivePaceSecondsPerKm)
        self.comparisonActivePaceSecondsPerKm = Self.positiveFiniteOptional(comparisonActivePaceSecondsPerKm)
        self.activePaceDeltaSecondsPerKm = Self.finiteOptional(activePaceDeltaSecondsPerKm)
    }

    public static let empty = ComparisonAlignedMetrics()

    public var primaryElapsedFormatted: String { DisplayFormatter.formatElapsed(primaryElapsedSeconds) }
    public var comparisonElapsedFormatted: String { DisplayFormatter.formatElapsed(comparisonElapsedSeconds) }
    public var primaryActiveFormatted: String { DisplayFormatter.formatElapsed(primaryActiveSeconds) }
    public var comparisonActiveFormatted: String { DisplayFormatter.formatElapsed(comparisonActiveSeconds) }
    public var primaryMovingFormatted: String { DisplayFormatter.formatElapsed(primaryMovingSeconds) }
    public var comparisonMovingFormatted: String { DisplayFormatter.formatElapsed(comparisonMovingSeconds) }
    public var primaryStoppedFormatted: String { DisplayFormatter.formatElapsed(primaryStoppedSeconds) }
    public var comparisonStoppedFormatted: String { DisplayFormatter.formatElapsed(comparisonStoppedSeconds) }
    public var primaryPaceFormatted: String { DisplayFormatter.formatPace(primaryActivePaceSecondsPerKm) }
    public var comparisonPaceFormatted: String { DisplayFormatter.formatPace(comparisonActivePaceSecondsPerKm) }
    public var elapsedDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            elapsedDeltaSeconds,
            positiveLabel: "longer",
            negativeLabel: "shorter"
        )
    }
    public var activeDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            activeDeltaSeconds,
            positiveLabel: "longer",
            negativeLabel: "shorter"
        )
    }
    public var movingDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            movingDeltaSeconds,
            positiveLabel: "more moving",
            negativeLabel: "less moving"
        )
    }
    public var stoppedDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(
            stoppedDeltaSeconds,
            positiveLabel: "more stopped",
            negativeLabel: "less stopped"
        )
    }
    public var paceDeltaFormatted: String {
        DisplayFormatter.formatSignedDurationDelta(activePaceDeltaSecondsPerKm, suffix: "/km")
    }
    public var spatialSeparationFormatted: String {
        guard spatialSeparationMeters.isFinite else { return "N/A" }
        if spatialSeparationMeters < 1 {
            return "<1 m apart"
        }
        return String(format: "%.0f m apart", spatialSeparationMeters)
    }

    private static func nonNegativeFinite(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
    private static func finiteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
    private static func nonNegativeFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    private static func positiveFiniteOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

/// Pace sample along matched route progress for charting.
public struct AlignedComparisonMetricPoint: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let alignedProgressMeters: Double
    public let primaryDistanceMeters: Double
    public let comparisonDistanceMeters: Double
    public let primaryPace: Double?
    public let comparisonPace: Double?
    public let paceDelta: Double?
    public let spatialSeparationMeters: Double
    public let blockIndex: Int

    public init(
        id: UUID = UUID(),
        alignedProgressMeters: Double,
        primaryDistanceMeters: Double,
        comparisonDistanceMeters: Double,
        primaryPace: Double?,
        comparisonPace: Double?,
        paceDelta: Double?,
        spatialSeparationMeters: Double,
        blockIndex: Int
    ) {
        self.id = id
        self.alignedProgressMeters = alignedProgressMeters.isFinite ? max(0, alignedProgressMeters) : 0
        self.primaryDistanceMeters = primaryDistanceMeters.isFinite ? max(0, primaryDistanceMeters) : 0
        self.comparisonDistanceMeters = comparisonDistanceMeters.isFinite ? max(0, comparisonDistanceMeters) : 0
        self.primaryPace = primaryPace.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.comparisonPace = comparisonPace.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.paceDelta = paceDelta.flatMap { $0.isFinite ? $0 : nil }
        self.spatialSeparationMeters = spatialSeparationMeters.isFinite ? max(0, spatialSeparationMeters) : 0
        self.blockIndex = max(0, blockIndex)
    }

    public var alignedProgressKm: Double { alignedProgressMeters / 1000 }
}

// MARK: - Load state (UI-facing but Core-owned for testing)

/// Explicit Route-Aware computation state.
public enum RouteAlignmentLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable(RouteAlignmentUnavailableReason)
    case failed(String)
}

// MARK: - Mapping helpers on snapshot

extension RouteAlignmentSnapshot {
    /// Map an aligned-progress value to primary/comparison distances.
    ///
    /// Interpolates only within a single alignment block. Never bridges gaps.
    public func positions(atAlignedProgress progress: Double) -> AlignedRoutePosition? {
        guard !blocks.isEmpty, totalAlignedDistanceMeters > 0 else { return nil }
        guard progress.isFinite else { return nil }

        let clamped = min(max(0, progress), totalAlignedDistanceMeters)
        guard let blockIndex = blockIndex(containing: clamped) else { return nil }
        let block = blocks[blockIndex]
        let anchors = block.anchors
        guard let first = anchors.first, let last = anchors.last else { return nil }

        if clamped <= first.alignedProgressMeters {
            return AlignedRoutePosition(
                alignedProgressMeters: first.alignedProgressMeters,
                blockIndex: blockIndex,
                primaryDistanceMeters: first.primaryDistanceMeters,
                comparisonDistanceMeters: first.comparisonDistanceMeters,
                spatialSeparationMeters: first.spatialSeparationMeters
            )
        }
        if clamped >= last.alignedProgressMeters {
            return AlignedRoutePosition(
                alignedProgressMeters: last.alignedProgressMeters,
                blockIndex: blockIndex,
                primaryDistanceMeters: last.primaryDistanceMeters,
                comparisonDistanceMeters: last.comparisonDistanceMeters,
                spatialSeparationMeters: last.spatialSeparationMeters
            )
        }

        var low = 0
        var high = anchors.count - 1
        while low < high {
            let mid = (low + high) / 2
            if anchors[mid].alignedProgressMeters < clamped {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 {
            let anchor = anchors[0]
            return AlignedRoutePosition(
                alignedProgressMeters: clamped,
                blockIndex: blockIndex,
                primaryDistanceMeters: anchor.primaryDistanceMeters,
                comparisonDistanceMeters: anchor.comparisonDistanceMeters,
                spatialSeparationMeters: anchor.spatialSeparationMeters
            )
        }
        let after = anchors[low]
        let before = anchors[low - 1]
        let span = after.alignedProgressMeters - before.alignedProgressMeters
        guard span > 0, span.isFinite else {
            return AlignedRoutePosition(
                alignedProgressMeters: after.alignedProgressMeters,
                blockIndex: blockIndex,
                primaryDistanceMeters: after.primaryDistanceMeters,
                comparisonDistanceMeters: after.comparisonDistanceMeters,
                spatialSeparationMeters: after.spatialSeparationMeters
            )
        }
        let fraction = (clamped - before.alignedProgressMeters) / span
        return AlignedRoutePosition(
            alignedProgressMeters: clamped,
            blockIndex: blockIndex,
            primaryDistanceMeters: lerp(before.primaryDistanceMeters, after.primaryDistanceMeters, fraction),
            comparisonDistanceMeters: lerp(before.comparisonDistanceMeters, after.comparisonDistanceMeters, fraction),
            spatialSeparationMeters: lerp(before.spatialSeparationMeters, after.spatialSeparationMeters, fraction)
        )
    }

    private func blockIndex(containing progress: Double) -> Int? {
        for (index, block) in blocks.enumerated() {
            if progress >= block.alignedStartMeters && progress <= block.alignedEndMeters {
                return index
            }
            // Between blocks: snap to the nearest boundary of the next/previous block.
            if progress < block.alignedStartMeters {
                return index
            }
        }
        return blocks.isEmpty ? nil : blocks.count - 1
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let clampedT = min(1, max(0, t))
        return a + (b - a) * clampedT
    }
}
