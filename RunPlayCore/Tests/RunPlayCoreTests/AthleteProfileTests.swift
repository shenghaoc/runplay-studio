import XCTest
@testable import RunPlayCore

final class AthleteProfileTests: XCTestCase {

    // MARK: - Effective profile derivation

    func testMeasuredMaximumWinsAndIsDisclosed() {
        let profile = AthleteProfile(
            birthYear: 1980,
            restingHeartRateBPM: 55,
            maximumHeartRateBPM: 192
        )
        let effective = profile.effectiveProfile(referenceYear: 2026)
        XCTAssertEqual(effective.maximumHeartRateBPM, 192)
        XCTAssertEqual(effective.maximumHeartRateOrigin, .measured)
        XCTAssertEqual(effective.restingHeartRateBPM, 55)
        XCTAssertNil(effective.ageYearsUsed)
    }

    func testTanakaEstimateFromBirthYear() {
        let profile = AthleteProfile(birthYear: 1986)
        let effective = profile.effectiveProfile(referenceYear: 2026)
        // Age 40: 208 - 0.7 × 40 = 180.
        XCTAssertEqual(effective.maximumHeartRateBPM, 180, accuracy: 1e-12)
        XCTAssertEqual(effective.maximumHeartRateOrigin, .ageEstimate)
        XCTAssertEqual(effective.ageYearsUsed, 40)
        XCTAssertEqual(effective.restingHeartRateBPM, AthleteProfile.defaultRestingHeartRateBPM)
    }

    func testPopulationDefaultWithoutAgeOrMaximum() {
        let effective = AthleteProfile().effectiveProfile(referenceYear: 2026)
        XCTAssertEqual(effective.maximumHeartRateBPM, AthleteProfile.defaultMaximumHeartRateBPM)
        XCTAssertEqual(effective.maximumHeartRateOrigin, .populationDefault)
        XCTAssertNil(effective.ageYearsUsed)
    }

    func testDefaultZonesAreFractionsOfMaximum() {
        let effective = AthleteProfile(maximumHeartRateBPM: 190)
            .effectiveProfile(referenceYear: 2026)
        XCTAssertEqual(effective.zoneLowerBoundsBPM.count, 5)
        XCTAssertEqual(effective.zoneLowerBoundsBPM[0], 0)
        XCTAssertEqual(effective.zoneLowerBoundsBPM[1], 114)  // 0.60 × 190
        XCTAssertEqual(effective.zoneLowerBoundsBPM[2], 133)  // 0.70 × 190
        XCTAssertEqual(effective.zoneLowerBoundsBPM[3], 152)  // 0.80 × 190
        XCTAssertEqual(effective.zoneLowerBoundsBPM[4], 171)  // 0.90 × 190
    }

    func testCustomZonesWinWhenWellFormed() {
        let custom: [Double] = [0, 110, 130, 150, 170]
        let effective = AthleteProfile(
            maximumHeartRateBPM: 190,
            customZoneLowerBoundsBPM: custom
        ).effectiveProfile(referenceYear: 2026)
        XCTAssertEqual(effective.zoneLowerBoundsBPM, custom)
    }

    func testMalformedCustomZonesFallBackToDerived() {
        for malformed in [[0.0, 110, 110, 150, 170], [0, 110, 130, 150], [0, 130, 110, 150, 170]] as [[Double]] {
            let effective = AthleteProfile(
                maximumHeartRateBPM: 190,
                customZoneLowerBoundsBPM: malformed
            ).effectiveProfile(referenceYear: 2026)
            XCTAssertEqual(effective.zoneLowerBoundsBPM, [0, 114, 133, 152, 171])
        }
    }

    func testDegenerateRestingClampedBelowMaximum() {
        let effective = AthleteProfile(
            restingHeartRateBPM: 200,
            maximumHeartRateBPM: 190
        ).effectiveProfile(referenceYear: 2026)
        XCTAssertLessThan(effective.restingHeartRateBPM, effective.maximumHeartRateBPM)
    }

    func testCoefficientProfilesCarryPublishedValues() {
        XCTAssertEqual(AthleteProfile.TRIMPCoefficientProfile.standardMale.multiplier, 0.64)
        XCTAssertEqual(AthleteProfile.TRIMPCoefficientProfile.standardMale.exponent, 1.92)
        XCTAssertEqual(AthleteProfile.TRIMPCoefficientProfile.standardFemale.multiplier, 0.86)
        XCTAssertEqual(AthleteProfile.TRIMPCoefficientProfile.standardFemale.exponent, 1.67)
    }

    func testProfileEqualityIsTheStalenessSignature() {
        XCTAssertEqual(AthleteProfile(), AthleteProfile())
        XCTAssertNotEqual(
            AthleteProfile(restingHeartRateBPM: 60),
            AthleteProfile(restingHeartRateBPM: 55)
        )
        XCTAssertNotEqual(
            AthleteProfile(birthYear: 1980),
            AthleteProfile()
        )
        XCTAssertNotEqual(
            AthleteProfile(trimpCoefficientProfile: .standardFemale),
            AthleteProfile(trimpCoefficientProfile: .standardMale)
        )
    }

    // MARK: - Profile store

    func testStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AthleteProfileStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileAthleteProfileStore(rootURL: directory)

        XCTAssertEqual(store.load(), .missing)
        XCTAssertEqual(store.loadOrDefault(), AthleteProfile())

        let profile = AthleteProfile(
            birthYear: 1990,
            restingHeartRateBPM: 52,
            maximumHeartRateBPM: 195,
            customZoneLowerBoundsBPM: [0, 115, 135, 155, 175],
            trimpCoefficientProfile: .standardFemale
        )
        try store.save(profile)
        XCTAssertEqual(store.load(), .loaded(profile))
        XCTAssertEqual(store.loadOrDefault(), profile)

        // Overwrite wins.
        try store.save(AthleteProfile(restingHeartRateBPM: 58))
        XCTAssertEqual(store.loadOrDefault(), AthleteProfile(restingHeartRateBPM: 58))
    }

    func testCorruptFileFallsBackToDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AthleteProfileStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileAthleteProfileStore(rootURL: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("athlete-profile.json"))

        XCTAssertEqual(store.load(), .corrupt)
        XCTAssertEqual(store.loadOrDefault(), AthleteProfile())
    }
}
