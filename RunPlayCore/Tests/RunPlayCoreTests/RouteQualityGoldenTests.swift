import Foundation
import RunPlayEngine
import RunPlayEngineTestSupport
import Testing
@testable import RunPlayCore

struct RouteQualityGoldenTests {
    private typealias Parity = RouteQualityParity

    // Derived from the C++ kernel before its removal. The Swift kernel was
    // asserted bit-identical to it on every fixture.
    private static let golden: UInt64? = {
        #if os(macOS) && arch(arm64)
        0x6edd5a41ea952c20
        #elseif os(Linux) && arch(x86_64)
        // Captured from the former C++ kernel in hosted Linux CI run 45327247726.
        0x6edd5a41ea952c20
        #else
        nil
        #endif
    }()

    /// Fails when a platform condition leaves `golden` nil on a platform that
    /// pins it, which would otherwise disable the golden test silently.
    @Test func goldenIsPinnedOnPinnedPlatforms() {
        #expect(
            !GoldenPlatform.current.pinsKernelGoldens || Self.golden != nil,
            "\(GoldenPlatform.unpinnedMessage("golden"))"
        )
    }

    @Test(.enabled(if: golden != nil))
    func swiftMatchesCppDerivedGolden() throws {
        let expected = try #require(Self.golden)
        var digest = FNV1a64()
        forEachFixture { _, inputs, strategy, selection, confirmationCount in
            let swift = Parity.swift(inputs, strategy, selection: selection, confirmationCount: confirmationCount)
            Self.append(swift, to: &digest)
        }
        #expect(digest.value == expected)
    }

    private static func append(_ result: Parity.Summary, to digest: inout FNV1a64) {
        digest.append(byte: result.status)
        digest.append(word: result.input)
        digest.append(word: result.retained)
        digest.append(word: result.discarded)
        digest.append(word: result.gaps)
        digest.append(word: result.segments)
        digest.append(byte: result.source)
        digest.append(word: result.totalBits)
        digest.append(word: UInt64(result.rows.count))
        for row in result.rows {
            digest.append(word: row.source)
            digest.append(word: row.segment)
            digest.append(word: row.distanceBits)
            digest.append(byte: row.distanceSource)
            digest.append(byte: row.retained)
            digest.append(byte: row.rejected)
            digest.append(byte: row.inferred)
        }
    }

    private func forEachFixture(
        _ visit: (String, [Parity.Input], Parity.Strategy, [UInt8]?, UInt64) -> Void
    ) {
        func compare(
            _ label: String, _ inputs: [Parity.Input], _ strategy: Parity.Strategy = .coordinates,
            selection: [UInt8]? = nil, confirmationCount: UInt64 = 3
        ) {
            visit(label, inputs, strategy, selection, confirmationCount)
        }
        compare("empty", [])
        compare("empty first", [], .suppliedForSelection, selection: [2], confirmationCount: 0)
        compare("one", [.init()])
        compare("first accuracy unchecked", [.init(accuracy: .nan)])
        compare("invalid policy before input", [.init(latitude: .nan)], confirmationCount: 1)
        compare("invalid latitude", [.init(latitude: .nan)])
        compare("invalid longitude", [.init(longitude: .infinity)])
        compare("invalid timestamp", [.init(timestamp: -.infinity)])
        compare("invalid elapsed", [.init(elapsed: .nan)])
        compare("selection missing", [.init()], .suppliedForSelection)
        compare("byte out of domain", [.init()], .suppliedForSelection, selection: [2])
        compare("selection present, nonselected policy", [.init()], selection: [])
        compare("inconsistent within-segment selection", [.init(), .init(source: 1)], .suppliedForSelection, selection: [1, 0])
        compare("first and last accuracy", [.init(), .init(source: 1, accuracy: -.infinity)])
        compare("segment gap", [.init(), .init(source: 1, segment: 2)])
        compare("subnormal and negative zero", [
            .init(latitude: -.leastNonzeroMagnitude, distance: -0.0),
            .init(source: 1, timestamp: 1, latitude: .leastNonzeroMagnitude, distance: 0.0, elapsed: 1),
        ], .allSupplied)
        compare("antimeridian, poles, Mercator limit", [
            .init(latitude: 85.0511287798066, longitude: 179.999999),
            .init(source: 1, timestamp: 300, latitude: 90, longitude: -179.999999, elapsed: 300),
            .init(source: 2, timestamp: 600, latitude: -90, longitude: 180, elapsed: 600),
        ])
        compare("inferred boundary and rejected point", route([0, 10, 5_000, 20, 30, 3_000, 3_010, 3_020, 3_030]))
        compare("adjacent flags", route([0, 0, 5_000, 0, 5_000, 0, 0]))
        compare("confirmation max wraps without accepting incomplete windows", route([0, 1, 3_000, 3_010]), confirmationCount: .max)

        var random = SplitMix64(seed: 0x4ee3_19ac_c6b9_b509)
        for length in [1, 2, 3, 8, 31, 64, 127, 512] {
            let rows = (0..<length).map { index -> Parity.Input in
                let latitude = Double(index) / 111_132 + Double(random.next() % 500) / 10_000_000
                let longitude = Double(random.next() % 100) / 100_000_000
                let metres = index % 37 == 7 ? -1.0 : Double(index)
                let t = Double(index)
                return .init(
                    source: random.next(), timestamp: t, latitude: latitude, longitude: longitude,
                    distance: metres, elapsed: t, segment: Int64(index / 11),
                    accuracy: index % 15 == 0 ? 120 : nil
                )
            }
            for strategy in Parity.Strategy.allCases {
                let selection = strategy == .suppliedForSelection ? rows.map { UInt8($0.segment % 2) } : nil
                compare("seeded: \(length), \(strategy)", rows, strategy, selection: selection)
            }
        }

        // Real allocated Spans at the product limit and above the kernel ceiling.
        let product = 1_000_000
        compare("product limit", Array(repeating: .init(), count: product), .allSupplied)
        compare("one above kernel ceiling", Array(repeating: .init(), count: 1_250_001))
    }

    private func route(_ metres: [Double]) -> [Parity.Input] {
        metres.enumerated().map {
            .init(
                source: UInt64($0.offset), timestamp: Double($0.offset), latitude: $0.element / 111_132,
                distance: Double($0.offset), elapsed: Double($0.offset), accuracy: 8
            )
        }
    }
}

// Raw forms used only by the golden corpus.
private enum RouteQualityParity {
    struct Input {
        var source: UInt64 = 0
        var timestamp = 0.0
        var latitude = 0.0
        var longitude = 0.0
        var distance = 0.0
        var elapsed = 0.0
        var segment: Int64 = 0
        var accuracy: Double?
    }

    enum Strategy: UInt8, CaseIterable {
        case coordinates, allSupplied, suppliedPerSegment, suppliedForSelection
    }

    struct Row: Equatable {
        let source: UInt64
        let segment: Int64
        let distanceBits: UInt64
        let distanceSource: UInt8
        let retained: UInt8
        let rejected: UInt8
        let inferred: UInt8
    }

    struct Summary: Equatable {
        let status: UInt8
        var input: UInt64 = 0
        var retained: UInt64 = 0
        var discarded: UInt64 = 0
        var gaps: UInt64 = 0
        var segments: UInt64 = 0
        var source: UInt8 = 0
        var totalBits: UInt64 = 0
        var rows: [Row] = []
    }

    static func swift(
        _ inputs: [Input], _ strategy: Strategy, selection: [UInt8]? = nil,
        confirmationCount: UInt64 = 3
    ) -> Summary {
        let distancePolicy: EngineRouteDistancePolicy = switch strategy {
        case .coordinates: .coordinates
        case .allSupplied: .allSupplied
        case .suppliedPerSegment: .suppliedPerSegment
        case .suppliedForSelection: .suppliedForSelection
        }
        let samples = inputs.map {
            EngineRouteInputSample(
                sourceIndex: $0.source, timestampSecondsSinceReferenceDate: $0.timestamp,
                latitude: $0.latitude, longitude: $0.longitude, distanceFromStartMeters: $0.distance,
                elapsedSeconds: $0.elapsed, horizontalAccuracy: $0.accuracy, routeSegmentIndex: $0.segment
            )
        }
        let policy = EngineRouteQualityPolicy(
            maximumRunningSpeed: 12, usefulAccuracy: 100,
            minimumSpikeExcess: 200, minimumSpikeDistortion: 3, poorAccuracyMultiplier: 0.5,
            minimumGapDistance: 200, minimumGapInterval: 120, minimumGapRatio: 3,
            confirmationCount: confirmationCount, maximumClusterStep: 200
        )

        do throws(RouteQualityError) {
            let summary: EngineRouteQualityResult
            if let selection {
                summary = try EngineRouteQuality.process(
                    samples.span, policy: policy, distancePolicy: distancePolicy, selection: selection.span
                )
            } else {
                summary = try EngineRouteQuality.process(
                    samples.span, policy: policy, distancePolicy: distancePolicy, selection: nil
                )
            }
            return Summary(
                status: 0, input: UInt64(summary.samples.count), retained: UInt64(summary.retainedCount),
                discarded: UInt64(summary.discardedCount), gaps: UInt64(summary.inferredGapCount),
                segments: UInt64(summary.segmentCount), source: summary.distanceSource.rawValue,
                totalBits: summary.totalDistance.bitPattern,
                rows: summary.samples.map {
                    Row(
                        source: $0.sourceIndex, segment: $0.normalizedSegmentIndex,
                        distanceBits: $0.normalizedDistance.bitPattern, distanceSource: $0.distanceSource.rawValue,
                        retained: $0.retained ? 1 : 0, rejected: $0.rejected ? 1 : 0, inferred: $0.inferredBoundary ? 1 : 0
                    )
                }
            )
        } catch {
            // Typed throws cannot return or mutate a caller-owned output on failure.
            let status: UInt8 = switch error {
            case .invalidSelectionBuffer: 4
            case .invalidPolicy: 5
            case .invalidInputContract: 6
            case .resourceLimit: 7
            }
            return Summary(status: status)
        }
    }
}
