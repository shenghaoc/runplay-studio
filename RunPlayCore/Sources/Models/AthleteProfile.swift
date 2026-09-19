import Foundation

/// Local-only athlete inputs used by heart-rate training-load computation.
///
/// Every field is optional on purpose: the feature never requires them. What
/// is not provided derives conservatively — maximum heart rate from birth year
/// through the Tanaka estimate (`208 − 0.7 × age`) or, without a birth year,
/// a population default — and the derivation that produced each stored load
/// is disclosed through `EffectiveTrainingLoadProfile`. The profile itself is
/// the staleness marker: a stored training-load snapshot records the profile
/// it was computed with, and a mismatch against the current profile is the
/// signal to recompute.
public struct AthleteProfile: Codable, Equatable, Hashable, Sendable {
    /// Population fallback when neither a measured maximum nor a birth year is
    /// available. An estimate, never presented as a measurement.
    public static let defaultMaximumHeartRateBPM: Double = 185

    /// Population fallback resting heart rate.
    public static let defaultRestingHeartRateBPM: Double = 60

    /// The published Banister coefficient sets. The two forms come from male
    /// and female cohorts; the choice scales load magnitude more than its
    /// shape, so fitness/fatigue/form trends are largely unaffected by it.
    public enum TRIMPCoefficientProfile: String, Codable, CaseIterable, Sendable {
        case standardMale
        case standardFemale

        /// The `y` in `y · e^(k · x)`.
        public var multiplier: Double {
            switch self {
            case .standardMale: return 0.64
            case .standardFemale: return 0.86
            }
        }

        /// The `k` in `y · e^(k · x)`.
        public var exponent: Double {
            switch self {
            case .standardMale: return 1.92
            case .standardFemale: return 1.67
            }
        }
    }

    /// Birth year, when provided. Age is the reference year minus the birth
    /// year — an approximation that ignores birthdays by at most one year,
    /// which moves the Tanaka estimate by under one beat per minute.
    public var birthYear: Int?

    /// Measured resting heart rate in beats per minute.
    public var restingHeartRateBPM: Double?

    /// Measured maximum heart rate in beats per minute. A measured value
    /// always wins over the age estimate.
    public var maximumHeartRateBPM: Double?

    /// Custom five-zone lower bounds in beats per minute, ascending. `nil`
    /// derives the default zone fractions of maximum heart rate.
    public var customZoneLowerBoundsBPM: [Double]?

    public var trimpCoefficientProfile: TRIMPCoefficientProfile

    public init(
        birthYear: Int? = nil,
        restingHeartRateBPM: Double? = nil,
        maximumHeartRateBPM: Double? = nil,
        customZoneLowerBoundsBPM: [Double]? = nil,
        trimpCoefficientProfile: TRIMPCoefficientProfile = .standardMale
    ) {
        self.birthYear = birthYear
        self.restingHeartRateBPM = restingHeartRateBPM
        self.maximumHeartRateBPM = maximumHeartRateBPM
        self.customZoneLowerBoundsBPM = customZoneLowerBoundsBPM
        self.trimpCoefficientProfile = trimpCoefficientProfile
    }

    /// Interior zone fractions of maximum heart rate for the default five-zone
    /// model: zone 1 is unbounded low, then 60, 70, 80, and 90 percent.
    public static let defaultZoneFractionsOfMaximum: [Double] = [0, 0.60, 0.70, 0.80, 0.90]

    /// Resolve the effective computation inputs, disclosing how the maximum
    /// heart rate was derived. `referenceYear` is injectable so derivation is
    /// testable; production passes the current calendar year.
    public func effectiveProfile(referenceYear: Int) -> EffectiveTrainingLoadProfile {
        let maximumOrigin: EffectiveTrainingLoadProfile.MaximumHeartRateOrigin
        let maximum: Double
        if let measured = maximumHeartRateBPM, measured.isFinite, measured > 0 {
            maximum = measured
            maximumOrigin = .measured
        } else if let year = birthYear {
            let age = max(0, referenceYear - year)
            maximum = 208.0 - 0.7 * Double(age)
            maximumOrigin = .ageEstimate
        } else {
            maximum = Self.defaultMaximumHeartRateBPM
            maximumOrigin = .populationDefault
        }

        let resting = restingHeartRateBPM.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        } ?? Self.defaultRestingHeartRateBPM

        // A degenerate profile (resting at or above maximum) must still
        // produce a valid kernel policy; clamp resting below maximum.
        let safeResting = min(resting, maximum - 1.0)

        var zoneBounds: [Double]
        if let custom = customZoneLowerBoundsBPM,
           custom.count == 5,
           custom.allSatisfy({ $0.isFinite }),
           zip(custom, custom.dropFirst()).allSatisfy({ $0 < $1 }) {
            zoneBounds = custom
        } else {
            zoneBounds = Self.defaultZoneFractionsOfMaximum.map { fraction in
                (fraction * maximum).rounded()
            }
            // Fractions of a valid maximum are strictly ascending already;
            // this guard keeps the promise even for extreme custom inputs.
            if !zip(zoneBounds, zoneBounds.dropFirst()).allSatisfy({ $0 < $1 }) {
                zoneBounds = Self.defaultZoneFractionsOfMaximum.map { fraction in
                    fraction * Self.defaultMaximumHeartRateBPM
                }
            }
        }

        return EffectiveTrainingLoadProfile(
            restingHeartRateBPM: safeResting,
            maximumHeartRateBPM: maximum,
            zoneLowerBoundsBPM: zoneBounds,
            coefficientMultiplier: trimpCoefficientProfile.multiplier,
            coefficientExponent: trimpCoefficientProfile.exponent,
            maximumHeartRateOrigin: maximumOrigin,
            ageYearsUsed: maximumOrigin == .ageEstimate ? max(0, referenceYear - (birthYear ?? referenceYear)) : nil
        )
    }
}

/// The concrete numeric inputs one training-load pass used, plus the
/// disclosure of how the maximum heart rate was derived.
public struct EffectiveTrainingLoadProfile: Equatable, Hashable, Sendable {
    public enum MaximumHeartRateOrigin: String, Codable, Equatable, Sendable {
        case measured
        case ageEstimate
        case populationDefault
    }

    public let restingHeartRateBPM: Double
    public let maximumHeartRateBPM: Double
    public let zoneLowerBoundsBPM: [Double]
    public let coefficientMultiplier: Double
    public let coefficientExponent: Double
    public let maximumHeartRateOrigin: MaximumHeartRateOrigin
    public let ageYearsUsed: Int?

    public init(
        restingHeartRateBPM: Double,
        maximumHeartRateBPM: Double,
        zoneLowerBoundsBPM: [Double],
        coefficientMultiplier: Double,
        coefficientExponent: Double,
        maximumHeartRateOrigin: MaximumHeartRateOrigin,
        ageYearsUsed: Int?
    ) {
        self.restingHeartRateBPM = restingHeartRateBPM
        self.maximumHeartRateBPM = maximumHeartRateBPM
        self.zoneLowerBoundsBPM = zoneLowerBoundsBPM
        self.coefficientMultiplier = coefficientMultiplier
        self.coefficientExponent = coefficientExponent
        self.maximumHeartRateOrigin = maximumHeartRateOrigin
        self.ageYearsUsed = ageYearsUsed
    }
}
