//  Generated from a capture taken at commit 1f5ee25, before the heart-rate
//  single-accessor refactor. Do not hand-edit the bit patterns: regenerate
//  from the pre-refactor commit if a fixture changes.
//
//  `banisterTRIMP` is the one field compared by accuracy rather than by exact
//  bit pattern. It is the only captured value that passes through std::exp in
//  the native kernel and exp() in the Swift estimator, and AGENTS.md is
//  explicit that libm results are not bit-stable across macOS and Linux. Every
//  other field is pure IEEE accumulation, comparison or division, so it is
//  pinned exactly and must hold on both platforms.

import XCTest
@testable import RunPlayCore

/// One fixture's pre-refactor training-load result.
struct LoadGolden {
    let kind: TrainingLoadSnapshot.Kind
    /// Compared with `accuracy: 1e-12`; see the file header for why.
    let banisterTRIMP: Double
    let zoneSeconds: [Double]?
    let meanHeartRateBPM: Double?
    let validHeartRateSeconds: Double
    let coveredActiveSeconds: Double
    let estimateBasis: TrainingLoadSnapshot.EstimateBasis?
    let assumedHeartRateReserve: Double?
}

/// One fixture's pre-refactor summary heart rate and totals.
struct SummaryGolden {
    let averageHeartRateBPM: Double?
    let maxHeartRateBPM: Double?
    let totalActiveSeconds: Double
    let totalDistanceMeters: Double
}

/// One fixture's pre-refactor distance-range heart-rate averages.
struct TimelineGolden {
    let totalDistanceMeters: Double
    /// Four equal-distance quarters, then the whole range, then an
    /// out-of-bounds range.
    let quarters: [Double?]
    let whole: Double?
    let outOfBounds: Double?
}

/// The pinned pre-refactor outputs, keyed by fixture name.
enum BehaviourPreservationGoldens {
    /// Relative tolerance for the one libm-derived field.
    static let trimpAccuracy: Double = 1e-12

    static let load: [String: LoadGolden] = [
        "A": LoadGolden(
            kind: .measured,
            banisterTRIMP: Double(bitPattern: 0x401e495e604f5cd0),
            zoneSeconds: [
                Double(bitPattern: 0x4092c00000000000),  // 1200.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
            ],
            meanHeartRateBPM: Double(bitPattern: 0x4059000000000000),  // 100.0
            validHeartRateSeconds: Double(bitPattern: 0x4092c00000000000),  // 1200.0
            coveredActiveSeconds: Double(bitPattern: 0x4092c00000000000),  // 1200.0
            estimateBasis: nil,
            assumedHeartRateReserve: nil,
        ),
        "B": LoadGolden(
            kind: .estimated,
            banisterTRIMP: Double(bitPattern: 0x4054426419e1bf85),
            zoneSeconds: nil,
            meanHeartRateBPM: nil,
            validHeartRateSeconds: Double(bitPattern: 0x0),  // 0.0
            coveredActiveSeconds: Double(bitPattern: 0x40a2c00000000000),  // 2400.0
            estimateBasis: .paceDuration,
            assumedHeartRateReserve: Double(bitPattern: 0x3fe8000000000000),  // 0.75
        ),
        "C": LoadGolden(
            kind: .estimated,
            banisterTRIMP: Double(bitPattern: 0x4025df8593211da6),
            zoneSeconds: nil,
            meanHeartRateBPM: nil,
            validHeartRateSeconds: Double(bitPattern: 0x0),  // 0.0
            coveredActiveSeconds: Double(bitPattern: 0x4080e00000000000),  // 540.0
            estimateBasis: .paceDuration,
            assumedHeartRateReserve: Double(bitPattern: 0x3fe3333333333333),  // 0.6
        ),
        "D": LoadGolden(
            kind: .estimated,
            banisterTRIMP: Double(bitPattern: 0x40184db0dc5daf2a),
            zoneSeconds: nil,
            meanHeartRateBPM: nil,
            validHeartRateSeconds: Double(bitPattern: 0x404e000000000000),  // 60.0
            coveredActiveSeconds: Double(bitPattern: 0x4072c00000000000),  // 300.0
            estimateBasis: .paceDuration,
            assumedHeartRateReserve: Double(bitPattern: 0x3fe3333333333333),  // 0.6
        ),
        "E": LoadGolden(
            kind: .measured,
            banisterTRIMP: Double(bitPattern: 0x404096c1ccbb6c7b),
            zoneSeconds: [
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x4081d00000000000),  // 570.0
                Double(bitPattern: 0x4081d00000000000),  // 570.0
                Double(bitPattern: 0x0),  // 0.0
            ],
            meanHeartRateBPM: Double(bitPattern: 0x4062700000000000),  // 147.5
            validHeartRateSeconds: Double(bitPattern: 0x4091d00000000000),  // 1140.0
            coveredActiveSeconds: Double(bitPattern: 0x4091d00000000000),  // 1140.0
            estimateBasis: nil,
            assumedHeartRateReserve: nil,
        ),
        "F": LoadGolden(
            kind: .measured,
            banisterTRIMP: Double(bitPattern: 0x402a453357353194),
            zoneSeconds: [
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x4085900000000000),  // 690.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
            ],
            meanHeartRateBPM: Double(bitPattern: 0x40609a6f4de9bd38),  // 132.82608695652175
            validHeartRateSeconds: Double(bitPattern: 0x4085900000000000),  // 690.0
            coveredActiveSeconds: Double(bitPattern: 0x4092480000000000),  // 1170.0
            estimateBasis: nil,
            assumedHeartRateReserve: nil,
        ),
        "G": LoadGolden(
            kind: .measured,
            banisterTRIMP: Double(bitPattern: 0x40283f02a134b214),
            zoneSeconds: [
                Double(bitPattern: 0x407e000000000000),  // 480.0
                Double(bitPattern: 0x407c200000000000),  // 450.0
                Double(bitPattern: 0x406e000000000000),  // 240.0
                Double(bitPattern: 0x0),  // 0.0
                Double(bitPattern: 0x0),  // 0.0
            ],
            meanHeartRateBPM: Double(bitPattern: 0x405bbd89d89d89d9),  // 110.96153846153847
            validHeartRateSeconds: Double(bitPattern: 0x4092480000000000),  // 1170.0
            coveredActiveSeconds: Double(bitPattern: 0x4092480000000000),  // 1170.0
            estimateBasis: nil,
            assumedHeartRateReserve: nil,
        ),
    ]

    static let summary: [String: SummaryGolden] = [
        "A": SummaryGolden(
            averageHeartRateBPM: Double(bitPattern: 0x4059000000000000),  // 100.0
            maxHeartRateBPM: Double(bitPattern: 0x4059000000000000),  // 100.0
            totalActiveSeconds: Double(bitPattern: 0x4092c00000000000),  // 1200.0
            totalDistanceMeters: Double(bitPattern: 0x40ac200000000000),  // 3600.0
        ),
        "B": SummaryGolden(
            averageHeartRateBPM: Double(bitPattern: 0x405ea00000000000),  // 122.5
            maxHeartRateBPM: Double(bitPattern: 0x4061800000000000),  // 140.0
            totalActiveSeconds: Double(bitPattern: 0x40a2c00000000000),  // 2400.0
            totalDistanceMeters: Double(bitPattern: 0x40c89c0000000000),  // 12600.0
        ),
        "C": SummaryGolden(
            averageHeartRateBPM: nil,
            maxHeartRateBPM: nil,
            totalActiveSeconds: Double(bitPattern: 0x4080e00000000000),  // 540.0
            totalDistanceMeters: Double(bitPattern: 0x4099500000000000),  // 1620.0
        ),
        "D": SummaryGolden(
            averageHeartRateBPM: Double(bitPattern: 0x40610e0000000000),  // 136.4375
            maxHeartRateBPM: Double(bitPattern: 0x4064000000000000),  // 160.0
            totalActiveSeconds: Double(bitPattern: 0x4072c00000000000),  // 300.0
            totalDistanceMeters: Double(bitPattern: 0x408c200000000000),  // 900.0
        ),
        "E": SummaryGolden(
            averageHeartRateBPM: Double(bitPattern: 0x4062700000000000),  // 147.5
            maxHeartRateBPM: Double(bitPattern: 0x4063600000000000),  // 155.0
            totalActiveSeconds: Double(bitPattern: 0x4091d00000000000),  // 1140.0
            totalDistanceMeters: Double(bitPattern: 0x40bbc60000000000),  // 7110.0
        ),
        "F": SummaryGolden(
            averageHeartRateBPM: Double(bitPattern: 0x40609b0000000000),  // 132.84375
            maxHeartRateBPM: Double(bitPattern: 0x4061000000000000),  // 136.0
            totalActiveSeconds: Double(bitPattern: 0x4092480000000000),  // 1170.0
            totalDistanceMeters: Double(bitPattern: 0x40ab6c0000000000),  // 3510.0
        ),
        "G": SummaryGolden(
            averageHeartRateBPM: Double(bitPattern: 0x405bc00000000000),  // 111.0
            maxHeartRateBPM: Double(bitPattern: 0x4061800000000000),  // 140.0
            totalActiveSeconds: Double(bitPattern: 0x4092480000000000),  // 1170.0
            totalDistanceMeters: Double(bitPattern: 0x40ab6c0000000000),  // 3510.0
        ),
    ]

    static let timeline: [String: TimelineGolden] = [
        "A": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x40ac200000000000),  // 3600.0
            quarters: [
                Double(bitPattern: 0x4059000000000000),  // 100.0
                Double(bitPattern: 0x4059000000000000),  // 100.0
                Double(bitPattern: 0x4059000000000000),  // 100.0
                Double(bitPattern: 0x4059000000000000),  // 100.0
            ],
            whole: Double(bitPattern: 0x4059000000000000),  // 100.0
            outOfBounds: Double(bitPattern: 0x4059000000000000),  // 100.0
        ),
        "B": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x40c89c0000000000),  // 12600.0
            quarters: [
                Double(bitPattern: 0x4059000000000000),  // 100.0
                Double(bitPattern: 0x405e000000000000),  // 120.0
                Double(bitPattern: 0x4060400000000000),  // 130.0
                Double(bitPattern: 0x4061800000000000),  // 140.0
            ],
            whole: Double(bitPattern: 0x405ea00000000000),  // 122.5
            outOfBounds: Double(bitPattern: 0x4061800000000000),  // 140.0
        ),
        "C": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x4099500000000000),  // 1620.0
            quarters: [
                nil,
                nil,
                nil,
                nil,
            ],
            whole: nil,
            outOfBounds: nil,
        ),
        "D": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x408c200000000000),  // 900.0
            quarters: [
                nil,
                Double(bitPattern: 0x4062300000000000),  // 145.5
                nil,
                Double(bitPattern: 0x4060ad5555555555),  // 133.41666666666666
            ],
            whole: Double(bitPattern: 0x40610e0000000000),  // 136.4375
            outOfBounds: Double(bitPattern: 0x4056000000000000),  // 88.0
        ),
        "E": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x40bbc60000000000),  // 7110.0
            quarters: [
                Double(bitPattern: 0x4061800000000000),  // 140.0
                Double(bitPattern: 0x4062700000000000),  // 147.5
                Double(bitPattern: 0x4062700000000000),  // 147.5
                Double(bitPattern: 0x4063600000000000),  // 155.0
            ],
            whole: Double(bitPattern: 0x4062700000000000),  // 147.5
            outOfBounds: Double(bitPattern: 0x4063600000000000),  // 155.0
        ),
        "F": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x40ab6c0000000000),  // 3510.0
            quarters: [
                Double(bitPattern: 0x4060900000000000),  // 132.5
                Double(bitPattern: 0x40609c0000000000),  // 132.875
                Double(bitPattern: 0x4060a80000000000),  // 133.25
                Double(bitPattern: 0x4060980000000000),  // 132.75
            ],
            whole: Double(bitPattern: 0x40609b0000000000),  // 132.84375
            outOfBounds: Double(bitPattern: 0x4060c00000000000),  // 134.0
        ),
        "G": TimelineGolden(
            totalDistanceMeters: Double(bitPattern: 0x40ab6c0000000000),  // 3510.0
            quarters: [
                Double(bitPattern: 0x405bc00000000000),  // 111.0
                Double(bitPattern: 0x405bc00000000000),  // 111.0
                Double(bitPattern: 0x405bc00000000000),  // 111.0
                Double(bitPattern: 0x405bc00000000000),  // 111.0
            ],
            whole: Double(bitPattern: 0x405bc00000000000),  // 111.0
            outOfBounds: Double(bitPattern: 0x4061800000000000),  // 140.0
        ),
    ]
}

