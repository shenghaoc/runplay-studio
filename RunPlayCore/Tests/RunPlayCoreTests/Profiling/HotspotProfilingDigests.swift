import Foundation
@testable import RunPlayCore

/// Deterministic digests for exact Mode A / Mode B parity.
enum HotspotProfilingDigests {
    static func workoutDigest(_ workout: RunWorkout) -> String {
        workoutDigest(workout, includeIdentity: true)
    }

    /// Import parity digest. Importers mint new workout/point IDs each call, so
    /// identity fields are excluded while all computational fields remain.
    static func importParityDigest(_ workout: RunWorkout) -> String {
        workoutDigest(workout, includeIdentity: false)
    }

    private static func workoutDigest(_ workout: RunWorkout, includeIdentity: Bool) -> String {
        var parts: [String] = []
        if includeIdentity {
            parts.append("id=\(workout.id.uuidString)")
        }
        parts.append("name=\(workout.metadata.name ?? "")")
        parts.append("src=\(workout.source.rawValue)")
        parts.append("pts=\(workout.routePoints.count)")
        parts.append("av=\(workout.analysisVersion)")
        parts.append("nv=\(workout.normalizationVersion)")
        parts.append("rds=\(String(describing: workout.routeDistanceSource))")
        parts.append("rdp=\(String(describing: workout.routeDistanceProvenance))")
        parts.append("sum=\(summaryDigest(workout.summary))")
        parts.append("splits=\(workout.splits.count)")
        for (i, s) in workout.splits.enumerated() {
            parts.append("sp\(i)=\(s.distanceMeters):\(s.elapsedSeconds):\(s.activeSeconds)")
        }
        parts.append("laps=\(workout.recordedLaps.count)")
        for (i, lap) in workout.recordedLaps.enumerated() {
            parts.append(
                "lp\(i)=\(lap.lapIndex):\(lap.startDistanceMeters):\(lap.endDistanceMeters):\(lap.elapsedSeconds):\(lap.distanceMeters)"
            )
        }
        parts.append("segs=\(workout.segments.count)")
        for (i, seg) in workout.segments.enumerated() {
            parts.append("sg\(i)=\(seg.startDistanceMeters):\(seg.endDistanceMeters):\(String(describing: seg.type))")
        }
        parts.append("warn=\(workout.analysisWarnings.map(\.rawValue).sorted().joined(separator: ","))")
        parts.append("mov=\(movementDigest(workout.movementDiagnostics))")
        parts.append("qual=\(qualityDigest(workout.qualityDiagnostics))")
        parts.append("lapd=\(lapDiagnosticsDigest(workout.recordedLapDiagnostics))")
        // Route points: computational fields. Identity UUIDs are optional.
        var pointHash: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in workout.routePoints {
            if includeIdentity {
                mix(&pointHash, p.id.uuidString)
            }
            mix(&pointHash, String(p.latitude))
            mix(&pointHash, String(p.longitude))
            mix(&pointHash, String(p.altitudeMeters ?? -1))
            mix(&pointHash, String(p.distanceFromStartMeters))
            mix(&pointHash, String(p.elapsedSeconds))
            mix(&pointHash, String(p.speedMetersPerSecond ?? -1))
            mix(&pointHash, String(p.paceSecondsPerKilometer ?? -1))
            mix(&pointHash, String(p.heartRateBPM ?? -1))
            mix(&pointHash, String(p.cadence ?? -1))
            mix(&pointHash, String(p.routeSegmentIndex))
            mix(&pointHash, String(p.timestamp.timeIntervalSinceReferenceDate))
        }
        parts.append("pth=\(String(pointHash, radix: 16))")
        return parts.joined(separator: "|")
    }

    static func alignmentDigest(_ snapshot: RouteAlignmentSnapshot) -> String {
        var parts: [String] = []
        parts.append("av=\(String(describing: snapshot.availability))")
        parts.append("pv=\(snapshot.policyVersion)")
        parts.append("blocks=\(snapshot.blocks.count)")
        for (bi, block) in snapshot.blocks.enumerated() {
            parts.append("b\(bi)=\(block.id):\(block.anchors.count)")
            for (ai, a) in block.anchors.enumerated() {
                parts.append(
                    "a\(bi).\(ai)=\(a.primaryDistanceMeters):\(a.comparisonDistanceMeters):\(a.alignedProgressMeters)"
                )
            }
        }
        let d = snapshot.diagnostics
        parts.append(
            "d=\(d.primarySampleCount):\(d.comparisonSampleCount):\(d.effectiveSampleIntervalMeters):\(String(describing: d.detectedDirection)):\(d.warnings.sorted().joined(separator: ","))"
        )
        parts.append(
            "dd=\(d.primaryRouteDistanceMeters):\(d.comparisonRouteDistanceMeters):\(d.alignedDistanceMeters):\(d.matchedBlockCount):\(d.meanSpatialSeparationMeters)"
        )
        return parts.joined(separator: "|")
    }

    static func metricProfileDigest(_ profile: RouteMetricProfile) -> String {
        var parts: [String] = []
        parts.append("mode=\(profile.mode.rawValue)")
        parts.append("iv=\(profile.intervals.count)")
        parts.append("cov=\(profile.validCoverageDistanceMeters)/\(profile.totalRouteDistanceMeters)")
        if let scale = profile.scale {
            parts.append("sc=\(scale.lowerBound):\(scale.median):\(scale.upperBound):\(scale.direction.rawValue)")
        } else {
            parts.append("sc=nil")
        }
        parts.append(
            "diag=\(profile.diagnostics.intervalCount):\(profile.diagnostics.validIntervalCount):\(profile.diagnostics.noDataIntervalCount):\(profile.diagnostics.validCoverageFraction)"
        )
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for iv in profile.intervals {
            mix(&h, String(iv.startPointIndex))
            mix(&h, String(iv.endPointIndex))
            mix(&h, String(iv.routeSegmentIndex))
            mix(&h, String(iv.startDistanceMeters))
            mix(&h, String(iv.endDistanceMeters))
            mix(&h, String(iv.metricValue ?? -1))
            mix(&h, String(iv.normalizedValue ?? -1))
            mix(&h, String(describing: iv.bucket))
        }
        parts.append("ih=\(String(h, radix: 16))")
        return parts.joined(separator: "|")
    }

    static func comparisonDigest(_ summary: WorkoutComparisonSummary) -> String {
        [
            summary.primaryTitle,
            summary.comparisonTitle,
            String(summary.primaryDistanceMeters),
            String(summary.comparisonDistanceMeters),
            String(summary.distanceDeltaMeters),
            String(summary.primaryActiveSeconds),
            String(summary.comparisonActiveSeconds),
            String(summary.primaryMovingSeconds),
            String(summary.comparisonMovingSeconds),
            String(summary.primaryPaceSecondsPerKm),
            String(summary.comparisonPaceSecondsPerKm)
        ].joined(separator: "|")
    }

    // MARK: - Private

    private static func summaryDigest(_ s: RunSummary) -> String {
        [
            s.totalDistanceMeters,
            s.totalElapsedSeconds,
            s.totalActiveSeconds,
            s.totalPausedSeconds,
            s.totalMovingSeconds,
            s.totalStoppedSeconds,
            s.movingPaceSecondsPerKilometer,
            s.averagePaceSecondsPerKilometer,
            s.elevationGainMeters,
            s.elevationLossMeters,
            s.averageHeartRateBPM ?? -1,
            s.maxHeartRateBPM ?? -1
        ].map { String($0) }.joined(separator: ",")
    }

    private static func movementDigest(_ d: MovementDiagnostics) -> String {
        "\(d.usedConservativeFallback):\(d.reliableIntervalCount):\(d.stoppedIntervalCount):\(d.uncertainIntervalCount):\(d.analysedPointPairCount)"
    }

    private static func qualityDigest(_ d: RouteQualityDiagnostics) -> String {
        "\(d.invalidCoordinatePointCount):\(d.discardedCoordinatePointCount):\(d.inferredRouteGapCount):\(d.discardedAltitudeSampleCount):\(d.invalidSourceSpeedSampleCount)"
    }

    private static func lapDiagnosticsDigest(_ d: RecordedLapDiagnostics) -> String {
        "\(d.sourceLapCount):\(d.importedLapCount):\(d.malformedLapCount):\(d.requiresReimportForSourceLaps)"
    }

    private static func mix(_ hash: inout UInt64, _ string: String) {
        for b in string.utf8 {
            hash ^= UInt64(b)
            hash &*= 0x100_0000_01b3
        }
    }
}
