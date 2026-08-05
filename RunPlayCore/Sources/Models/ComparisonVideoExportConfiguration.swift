import Foundation

/// User-facing configuration for two-workout comparison replay video export.
///
/// Sheet-local only — never persisted into application session state.
public struct ComparisonVideoExportConfiguration: Codable, Hashable, Sendable {
    public var duration: WorkoutVideoDuration
    public var appearance: PNGSummaryExportAppearance
    public var alignmentMode: ComparisonAlignmentMode

    public init(
        duration: WorkoutVideoDuration = .thirtySeconds,
        appearance: PNGSummaryExportAppearance = .light,
        alignmentMode: ComparisonAlignmentMode = .distance
    ) {
        self.duration = duration
        self.appearance = appearance
        self.alignmentMode = alignmentMode
    }
}

/// Comparison-domain kind used by the offline frame plan.
public enum ComparisonVideoDomain: String, Hashable, Sendable, Codable {
    case commonDistance
    case alignedProgress

    public var displayName: String {
        switch self {
        case .commonDistance: return "Common Distance"
        case .alignedProgress: return "Matched Route"
        }
    }
}

/// Progress phases for comparison-video preparation and encoding.
///
/// Reuses the single-workout phase vocabulary where possible and adds
/// alignment-specific states for the comparison sheet.
public enum ComparisonVideoExportPhase: String, Hashable, Sendable {
    case idle
    case preparingAlignment
    case alignmentUnavailable
    case preparingRoute
    case loadingMap
    case renderingPoster
    case awaitingDestination
    case encoding
    case cancelling
    case finalizing
    case completed
    case cancelled
    case failed

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .preparingAlignment: return "Aligning routes"
        case .alignmentUnavailable: return "Route-Aware unavailable"
        case .preparingRoute: return "Preparing routes"
        case .loadingMap: return "Loading map"
        case .renderingPoster: return "Rendering preview"
        case .awaitingDestination: return "Choose destination"
        case .encoding: return "Encoding video"
        case .cancelling: return "Cancelling"
        case .finalizing: return "Finalizing"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    /// Maps into the shared video progress phase used by the H.264 writer.
    public var sharedVideoPhase: WorkoutVideoExportPhase {
        switch self {
        case .idle: return .idle
        case .preparingAlignment, .preparingRoute: return .preparingRoute
        case .alignmentUnavailable: return .failed
        case .loadingMap: return .loadingMap
        case .renderingPoster: return .renderingPoster
        case .awaitingDestination: return .awaitingDestination
        case .encoding: return .encoding
        case .cancelling: return .cancelling
        case .finalizing: return .finalizing
        case .completed: return .completed
        case .cancelled: return .cancelled
        case .failed: return .failed
        }
    }
}

/// Structured errors for comparison video export.
public enum ComparisonVideoExportError: Error, LocalizedError, Sendable, Equatable {
    case ineligiblePair(String)
    case noUsableRoute
    case noCommonDistance
    case routeAwareUnavailable(RouteAlignmentUnavailableReason)
    case routeAwarePolicyMismatch
    case invalidConfiguration(String)
    case mapPreparationFailed(String)
    case encodingFailed(WorkoutVideoExportError)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .ineligiblePair(let detail):
            return detail
        case .noUsableRoute:
            return "One or both workouts have no usable GPS route for comparison video export."
        case .noCommonDistance:
            return "These workouts have no positive common distance for Distance-aligned export."
        case .routeAwareUnavailable(let reason):
            return reason.userFacingExplanation
        case .routeAwarePolicyMismatch:
            return "Route-Aware alignment is incompatible with the current alignment policy."
        case .invalidConfiguration(let detail):
            return "Invalid comparison video configuration: \(detail)"
        case .mapPreparationFailed(let detail):
            return "Map preparation failed: \(detail)"
        case .encodingFailed(let error):
            return error.errorDescription
        case .cancelled:
            return "Comparison video export cancelled."
        }
    }

    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        if case .encodingFailed(let error) = self { return error.isCancellation }
        return false
    }
}

/// Portable eligibility for comparison video export (no MapKit).
public enum ComparisonVideoExportEligibility: Sendable {
    public struct Assessment: Equatable, Sendable {
        public let canExportDistance: Bool
        public let canExportRouteAware: Bool
        public let distanceUnavailableHelp: String?
        public let routeAwareUnavailableHelp: String?
        public let routeAwareUnavailableReason: RouteAlignmentUnavailableReason?

        public init(
            canExportDistance: Bool,
            canExportRouteAware: Bool,
            distanceUnavailableHelp: String?,
            routeAwareUnavailableHelp: String?,
            routeAwareUnavailableReason: RouteAlignmentUnavailableReason? = nil
        ) {
            self.canExportDistance = canExportDistance
            self.canExportRouteAware = canExportRouteAware
            self.distanceUnavailableHelp = distanceUnavailableHelp
            self.routeAwareUnavailableHelp = routeAwareUnavailableHelp
            self.routeAwareUnavailableReason = routeAwareUnavailableReason
        }

        public var canOpenSheet: Bool { canExportDistance }
    }

    /// True when the workout has at least one coordinate usable for a route map.
    public static func hasUsableRoute(_ workout: RunWorkout) -> Bool {
        workout.routePoints.contains { point in
            GeoDistance.isValidCoordinate(lat: point.latitude, lon: point.longitude)
        }
    }

    public static func commonDistanceMeters(
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext
    ) -> Double {
        min(
            primaryContext.timeline.totalDistanceMeters,
            comparisonContext.timeline.totalDistanceMeters
        )
    }

    /// Distance-mode eligibility for an ordered pair.
    public static func distanceAssessment(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext
    ) -> Assessment {
        if pair.primary.id == pair.comparison.id {
            return Assessment(
                canExportDistance: false,
                canExportRouteAware: false,
                distanceUnavailableHelp: "Select two different workouts to export a comparison video.",
                routeAwareUnavailableHelp: "Select two different workouts to export a comparison video."
            )
        }
        let primaryRoute = hasUsableRoute(pair.primary)
        let comparisonRoute = hasUsableRoute(pair.comparison)
        if !primaryRoute || !comparisonRoute {
            return Assessment(
                canExportDistance: false,
                canExportRouteAware: false,
                distanceUnavailableHelp:
                    "One or both workouts have no usable GPS route for comparison video export.",
                routeAwareUnavailableHelp:
                    "One or both workouts have no usable GPS route for comparison video export.",
                routeAwareUnavailableReason: .insufficientRouteData
            )
        }
        let common = commonDistanceMeters(
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        if !(common.isFinite && common > 0) {
            return Assessment(
                canExportDistance: false,
                canExportRouteAware: false,
                distanceUnavailableHelp:
                    "These workouts have no positive common distance for Distance-aligned export.",
                routeAwareUnavailableHelp:
                    "These workouts have no positive common distance for Distance-aligned export."
            )
        }
        return Assessment(
            canExportDistance: true,
            canExportRouteAware: false,
            distanceUnavailableHelp: nil,
            routeAwareUnavailableHelp: "Route-Aware alignment has not been prepared yet.",
            routeAwareUnavailableReason: nil
        )
    }

    /// Full Distance + Route-Aware assessment when a snapshot is available.
    public static func assessment(
        pair: ComparisonPair,
        primaryContext: WorkoutAnalysisContext,
        comparisonContext: WorkoutAnalysisContext,
        snapshot: RouteAlignmentSnapshot?,
        policy: RouteAlignmentPolicy = .default
    ) -> Assessment {
        let base = distanceAssessment(
            pair: pair,
            primaryContext: primaryContext,
            comparisonContext: comparisonContext
        )
        guard base.canExportDistance else { return base }

        guard let snapshot else {
            return base
        }

        if snapshot.policyVersion != policy.algorithmVersion {
            return Assessment(
                canExportDistance: true,
                canExportRouteAware: false,
                distanceUnavailableHelp: nil,
                routeAwareUnavailableHelp:
                    "Route-Aware alignment is incompatible with the current alignment policy.",
                routeAwareUnavailableReason: .algorithmFailure
            )
        }

        switch snapshot.availability {
        case .unavailable(let reason):
            return Assessment(
                canExportDistance: true,
                canExportRouteAware: false,
                distanceUnavailableHelp: nil,
                routeAwareUnavailableHelp: reason.userFacingExplanation,
                routeAwareUnavailableReason: reason
            )
        case .available:
            let aligned = snapshot.totalAlignedDistanceMeters
            let hasBlocks = !snapshot.blocks.isEmpty
            if aligned.isFinite, aligned > 0, hasBlocks {
                return Assessment(
                    canExportDistance: true,
                    canExportRouteAware: true,
                    distanceUnavailableHelp: nil,
                    routeAwareUnavailableHelp: nil,
                    routeAwareUnavailableReason: nil
                )
            }
            return Assessment(
                canExportDistance: true,
                canExportRouteAware: false,
                distanceUnavailableHelp: nil,
                routeAwareUnavailableHelp:
                    RouteAlignmentUnavailableReason.insufficientMatchedDistance.userFacingExplanation,
                routeAwareUnavailableReason: .insufficientMatchedDistance
            )
        }
    }

    public static func canExport(
        mode: ComparisonAlignmentMode,
        assessment: Assessment
    ) -> Bool {
        switch mode {
        case .distance: return assessment.canExportDistance
        case .routeAware: return assessment.canExportRouteAware
        }
    }
}
