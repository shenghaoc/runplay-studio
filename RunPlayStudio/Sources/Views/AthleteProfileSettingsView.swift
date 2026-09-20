import SwiftUI
import RunPlayCore

/// Settings-scene progress for an explicit training-load recompute pass.
enum TrainingLoadRecomputeState: Equatable {
    case idle
    case running(completedCount: Int, totalCount: Int, currentWorkoutName: String)
    case failed(String)
}

/// Athlete profile settings (⌘,): the local-only inputs behind training
/// load, the derived-value disclosures, and the explicit recompute action.
///
/// Nothing here is required. Blank fields mean the app derives conservative
/// defaults and says so; every derived value is previewed before it is
/// saved, and a measured maximum heart rate always wins over the age
/// estimate.
struct AthleteProfileSettingsView: View {
    @ObservedObject var appState: AppState

    @State private var birthYearText = ""
    @State private var restingHeartRateText = ""
    @State private var maximumHeartRateText = ""
    @State private var customZoneTexts: [String] = ["", "", "", "", ""]
    @State private var coefficientProfile: AthleteProfile.TRIMPCoefficientProfile = .standardMale
    @State private var hasLoadedDraft = false

    var body: some View {
        Form {
            athleteSection
            zonesSection
            coefficientSection
            trainingLoadSection
            privacyFooter
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 520)
        .onAppear(perform: loadDraft)
    }

    // MARK: - Athlete

    private var athleteSection: some View {
        Section {
            TextField("Birth year (optional)", text: $birthYearText)
                .help("Used only to estimate maximum heart rate when no measured value is entered")
            TextField("Resting heart rate (optional, bpm)", text: $restingHeartRateText)
            TextField("Maximum heart rate (optional, bpm)", text: $maximumHeartRateText)
                .help("A measured value always wins over the age estimate")
            if let estimate = derivedMaximumEstimate {
                Text(estimate)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Athlete")
        } footer: {
            Text("Blank fields use population defaults (resting 60 bpm) and the Tanaka age estimate for maximum heart rate — both are estimates, clearly disclosed on every computed load. None of this is medical guidance.")
        }
    }

    private var derivedMaximumEstimate: String? {
        if let measured = parse(maximumHeartRateText), measured > 0 {
            return nil
        }
        guard let year = Int(birthYearText), year > 1900, year <= currentYear else { return nil }
        let age = currentYear - year
        return "Estimated maximum from age \(age): \(Int((208.0 - 0.7 * Double(age)).rounded())) bpm (Tanaka) — entering a measured value is the upgrade."
    }

    private var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }

    // MARK: - Zones

    private var zonesSection: some View {
        Section {
            HStack(spacing: AppDesign.Spacing.small) {
                ForEach(0..<5, id: \.self) { index in
                    TextField(zonePlaceholder(index), text: $customZoneTexts[index])
                        .multilineTextAlignment(.trailing)
                }
            }
            Text(effectiveZoneSummary)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
        } header: {
            Text("Heart-rate zones")
        } footer: {
            Text("Five ascending lower bounds in bpm. Leave blank to derive the default zones (60, 70, 80, 90 percent of maximum heart rate, zone 1 unbounded low).")
        }
    }

    private var effectiveZoneSummary: String {
        let effective = draftProfile.effectiveProfile(referenceYear: currentYear)
        let bounds = effective.zoneLowerBoundsBPM
            .map { $0 == 0 ? "open" : "\(Int($0.rounded()))" }
            .joined(separator: " / ")
        return "Effective zone bounds: \(bounds) bpm"
    }

    private func zonePlaceholder(_ index: Int) -> String {
        let derived = appState.athleteProfile
            .effectiveProfile(referenceYear: currentYear)
            .zoneLowerBoundsBPM
        let value = derived[index]
        return index == 0 && value == 0 ? "open" : "\(Int(value.rounded()))"
    }

    // MARK: - Coefficients

    private var coefficientSection: some View {
        Section {
            Picker("Coefficient set", selection: $coefficientProfile) {
                ForEach(AthleteProfile.TRIMPCoefficientProfile.allCases, id: \.self) { profile in
                    Text(coefficientTitle(profile)).tag(profile)
                }
            }
        } header: {
            Text("TRIMP coefficients")
        } footer: {
            Text("The two published Banister coefficient sets come from male and female cohorts. The choice scales the magnitude of your loads more than their shape, so fitness, fatigue, and form trends are largely unaffected by picking the 'wrong' one. Leave the default if unsure.")
        }
    }

    private func coefficientTitle(
        _ profile: AthleteProfile.TRIMPCoefficientProfile
    ) -> String {
        switch profile {
        case .standardMale: return "Standard (male cohort)"
        case .standardFemale: return "Female cohort"
        }
    }

    // MARK: - Training load

    private var trainingLoadSection: some View {
        Section {
            Button("Update Profile") { applyDraft() }
                .disabled(!draftDiffers)
            if draftDiffers {
                Text("The profile shown above is not saved yet.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
            }
            staleLoadDisclosure
            recomputeControls
        } header: {
            Text("Training load")
        } footer: {
            Text("Runs without usable heart rate get a clearly-labelled estimated load from pace and duration. Estimates are informative per run but stay out of the fitness/fatigue/form model by default — inventing inputs would bias the curve downward, which understates fatigue. You can opt in on the Trends chart if you mostly run without a strap.")
        }
    }

    @ViewBuilder
    private var staleLoadDisclosure: some View {
        let staleCount = appState.staleTrainingLoadCount
        if staleCount > 0 {
            Text("\(staleCount) run\(staleCount == 1 ? "" : "s") would be recomputed under the saved profile.")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recomputeControls: some View {
        switch appState.trainingLoadRecomputeState {
        case .idle:
            Button("Recompute Training Loads") {
                appState.recomputeTrainingLoads()
            }
            .disabled(appState.trainingLoadBackfillTaskActive)
        case .running(let completed, let total, let name):
            VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0) {
                    Text("Recomputing — \(completed) of \(total) runs\(name.isEmpty ? "" : " — \(name)")")
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    appState.cancelTrainingLoadPass()
                }
            }
        case .failed(let message):
            Text(message)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var privacyFooter: some View {
        Section {
            Text("This profile is stored only on this Mac, beside your workout library. RunPlay Studio has no accounts, no cloud, and no telemetry.")
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Draft handling

    private func loadDraft() {
        guard !hasLoadedDraft else { return }
        hasLoadedDraft = true
        let profile = appState.athleteProfile
        birthYearText = profile.birthYear.map(String.init) ?? ""
        restingHeartRateText = profile.restingHeartRateBPM
            .map { String(Int($0.rounded())) } ?? ""
        maximumHeartRateText = profile.maximumHeartRateBPM
            .map { String(Int($0.rounded())) } ?? ""
        customZoneTexts = profile.customZoneLowerBoundsBPM?
            .map { String(Int($0.rounded())) } ?? ["", "", "", "", ""]
        coefficientProfile = profile.trimpCoefficientProfile
    }

    private var draftProfile: AthleteProfile {
        AthleteProfile(
            birthYear: Int(birthYearText),
            restingHeartRateBPM: parse(restingHeartRateText),
            maximumHeartRateBPM: parse(maximumHeartRateText),
            customZoneLowerBoundsBPM: parsedCustomZones(),
            trimpCoefficientProfile: coefficientProfile
        )
    }

    private var draftDiffers: Bool {
        draftProfile != appState.athleteProfile
    }

    private func parsedCustomZones() -> [Double]? {
        let texts = customZoneTexts
        if texts.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return nil
        }
        let values = texts.map { parse($0) }
        // Partial or malformed input keeps the previously saved zones.
        guard values.allSatisfy({ $0 != nil }),
              let bounds = values.compactMap({ $0 }) as [Double]?,
              zip(bounds, bounds.dropFirst()).allSatisfy({ $0 < $1 }) else {
            return appState.athleteProfile.customZoneLowerBoundsBPM
        }
        return bounds
    }

    private func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else {
            return nil
        }
        return value
    }

    private func applyDraft() {
        appState.updateAthleteProfile(draftProfile)
    }
}
