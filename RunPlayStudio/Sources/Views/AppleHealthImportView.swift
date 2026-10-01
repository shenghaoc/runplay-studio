import SwiftUI
import RunPlayCore
import RunPlayPlatform

/// Sheet for reviewing, importing, and reporting an Apple Health export.
///
/// The review is the only place a workout from the export can be added to the
/// library, and the sheet never adds one itself: it hands the checked candidates
/// to `AppleHealthImportService`, which owns the batch seam. Cancelling is
/// therefore always safe — the sheet asks, and the library is left as it was.
struct AppleHealthImportView: View {

    @ObservedObject var session: AppleHealthImportSession
    var onImport: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void
    var onViewImported: () -> Void

    @State private var focusedCandidateID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch session.phase {
            case .reviewing:
                reviewBody
            case .importing:
                progressBody
            case .report:
                reportBody
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .background(AppDesign.workspaceBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.xSmall) {
                Text("Import Apple Health Export")
                    .font(AppDesign.Typography.heading2)
                Text(session.archiveName)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if session.phase == .reviewing {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import Apple Health Export, \(session.archiveName)")
    }

    // MARK: - Review

    private var reviewBody: some View {
        VStack(spacing: 0) {
            summaryBar
            if let skipped = AppleHealthReviewPresentation.skippedNonRunningText(
                session.scanResult.report.excludedWorkoutCount
            ) {
                Text(skipped)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, AppDesign.Spacing.small)
            }
            filterBar
            candidateTable
            flagDetail
            reviewFooter
        }
    }

    private var summaryBar: some View {
        HStack(spacing: AppDesign.Spacing.large) {
            summaryChip("Workouts", "\(session.candidates.count)")
            summaryChip("Ready", "\(session.readyCount)")
            summaryChip("Selected", "\(session.selectedCount)")
            summaryChip("Flagged", "\(session.flaggedCount)")
            summaryChip("With a route", "\(session.candidates.count { $0.hasRoute })")
            summaryChip("With heart rate", "\(session.candidates.count { !$0.heartRate.isEmpty })")
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, AppDesign.Spacing.medium)
    }

    private func summaryChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(title)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppDesign.Typography.bodySemibold)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private var filterBar: some View {
        HStack {
            TextField("Search workouts", text: $session.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .accessibilityLabel("Search workouts")

            Toggle("Flagged only", isOn: $session.flaggedOnly)
                .toggleStyle(.checkbox)
                .help("Show only the workouts that are duplicates or overlaps. They start unchecked.")

            Spacer()

            Button("Select All Ready") { session.selectAllReady() }
                .help("Check every workout that carries no duplicate flag")

            Button("Select None") { session.selectNone() }
        }
        .padding(.horizontal)
        .padding(.bottom, AppDesign.Spacing.small)
    }

    private var candidateTable: some View {
        Table(session.filteredCandidates, selection: $focusedCandidateID) {
            TableColumn("Import") { candidate in
                Toggle("", isOn: selectionBinding(for: candidate))
                    .labelsHidden()
                    .accessibilityLabel(AppleHealthReviewPresentation.rowAccessibilityLabel(candidate))
            }
            .width(56)

            TableColumn("Date") { candidate in
                Text(AppleHealthReviewPresentation.dateText(candidate.window))
                    .font(AppDesign.Typography.compactLabel)
            }
            .width(min: 220, ideal: 230, max: 260)

            TableColumn("Type") { candidate in
                Text(AppleHealthReviewPresentation.activityName(candidate.window.activityType))
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 90, max: 110)

            TableColumn("Duration") { candidate in
                Text(AppleHealthReviewPresentation.durationText(candidate.window))
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 90, max: 100)

            TableColumn("Distance") { candidate in
                Text(AppleHealthReviewPresentation.distanceText(candidate))
                    .monospacedDigit()
                    .help(AppleHealthReviewPresentation.distanceHelp(candidate))
            }
            .width(min: 80, ideal: 90, max: 110)

            TableColumn("Route") { candidate in
                indicator(AppleHealthReviewPresentation.hasRoute(candidate))
                    .accessibilityLabel(AppleHealthReviewPresentation.routeAccessibilityLabel(candidate))
            }
            .width(52)

            TableColumn("HR") { candidate in
                indicator(AppleHealthReviewPresentation.hasHeartRate(candidate))
                    .accessibilityLabel(AppleHealthReviewPresentation.heartRateAccessibilityLabel(candidate))
            }
            .width(40)

            TableColumn("Flag") { candidate in
                if let reason = AppleHealthReviewPresentation.flagText(candidate) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(reason)
                        .accessibilityLabel(reason)
                }
            }
            .width(48)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("Apple Health workout candidates")
    }

    private var flagDetail: some View {
        let focused = session.filteredCandidates.first { $0.id == focusedCandidateID }
        return Group {
            if let text = AppleHealthReviewPresentation.flagDetailText(
                selectedCandidate: focused, flaggedCount: session.flaggedCount
            ) {
                Text(text)
                    .font(AppDesign.Typography.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, AppDesign.Spacing.small)
            }
        }
    }

    private func selectionBinding(for candidate: AppleHealthWorkoutCandidate) -> Binding<Bool> {
        Binding(
            get: { session.selectedIDs.contains(candidate.id) },
            set: { isOn in
                focusedCandidateID = candidate.id
                if isOn {
                    session.selectedIDs.insert(candidate.id)
                } else {
                    session.selectedIDs.remove(candidate.id)
                }
            }
        )
    }

    private func indicator(_ isPresent: Bool) -> some View {
        Image(systemName: isPresent ? "checkmark" : "minus")
            .foregroundStyle(isPresent ? Color.primary : Color.secondary)
    }

    private var reviewFooter: some View {
        HStack(alignment: .firstTextBaseline) {
            if session.flaggedCount > 0 {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("\(session.flaggedCount) flagged workouts start unchecked. Turn one on to import it anyway.")
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Import \(session.selectedCount) \(session.selectedCount == 1 ? "Workout" : "Workouts")") {
                onImport()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(session.selectedCount == 0)
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Progress

    private var progressBody: some View {
        VStack(spacing: AppDesign.Spacing.xxxLarge) {
            Spacer()
            ProgressView(value: progressFraction) {
                Text(phaseLabel(session.progress.phase))
                    .font(AppDesign.Typography.bodySemibold)
            } currentValueLabel: {
                Text(progressCaption)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 420)
            .padding(.horizontal, 40)
            .accessibilityLabel("Import progress")
            .accessibilityValue(progressCaption)

            Button("Cancel", action: onCancel)
                .help("Cancel the import and leave your library unchanged")
                .disabled(session.progress.phase == .committing)

            Spacer()
        }
    }

    private var progressFraction: Double {
        min(1, Double(session.progress.completedCount) / Double(max(session.progress.totalCount, 1)))
    }

    private var progressCaption: String {
        let progress = session.progress
        return "\(progress.completedCount) of \(progress.totalCount) · staged \(progress.stagedCount)"
            + " · already in your library \(progress.skippedCount) · failed \(progress.failedCount)"
    }

    private func phaseLabel(_ phase: AppleHealthImportProgress.Phase) -> String {
        switch phase {
        case .importing: return "Reading workouts…"
        case .staging: return "Staging workouts…"
        case .committing: return "Saving your library…"
        case .completed: return "Complete"
        case .cancelled: return "Cancelled"
        }
    }

    // MARK: - Report

    private var reportBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.large) {
                if let report = session.report {
                    let summary = AppleHealthImportSummary(report: report)
                    Text(summary.headline)
                        .font(AppDesign.Typography.heading2)
                        .foregroundStyle(headlineColor(summary.outcome))

                    if let error = session.errorMessage ?? report.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: AppDesign.Spacing.large) {
                        reportStat("Imported", report.importedCount)
                        reportStat("Without a route", report.importedWithoutRouteCount)
                        reportStat("Already in your library", report.alreadyInLibraryCount)
                        reportStat("Could not be read", report.failedCount)
                        reportStat("Not saved", report.discardedCount)
                    }

                    // The two counts that come from the export rather than from
                    // the selection, as figures as well as in the prose below.
                    // Neither can be inferred from the list of imported runs,
                    // which is why they are stated twice.
                    if summary.droppedWorkoutCount > 0 || summary.unmatchedRouteReferenceCount > 0 {
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
                            if summary.droppedWorkoutCount > 0 {
                                Text("Workouts the export describes that this import cannot read: \(summary.droppedWorkoutCount)")
                            }
                            if summary.unmatchedRouteReferenceCount > 0 {
                                Text("Workouts naming a route file the archive does not contain: \(summary.unmatchedRouteReferenceCount)")
                            }
                        }
                        .font(AppDesign.Typography.secondary)
                        .foregroundStyle(.secondary)
                    }

                    if !summary.lines.isEmpty {
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.small) {
                            ForEach(summary.lines, id: \.self) { line in
                                Text(line)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Import report details")
                    }

                    if !report.items.isEmpty {
                        DisclosureGroup("Details") {
                            List(report.items, id: \.candidateID) { item in
                                let outcome = AppleHealthReviewPresentation.itemOutcomeText(item)
                                HStack {
                                    Text(AppleHealthReviewPresentation.itemTitle(item))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(outcome)
                                        .foregroundStyle(.secondary)
                                }
                                .help(item.detail ?? outcome)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(AppleHealthReviewPresentation.itemTitle(item)), \(outcome)")
                            }
                            .frame(minHeight: 120, maxHeight: 240)
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Done", action: onDone)
                            .keyboardShortcut(.defaultAction)
                        if report.selectedWorkoutID != nil {
                            Button("View Imported Run", action: onViewImported)
                        }
                    }
                } else {
                    Text("No report available.")
                    Button("Done", action: onDone)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headlineColor(_ outcome: AppleHealthImportSummary.Outcome) -> Color {
        switch outcome {
        case .added: return .primary
        case .nothingNew: return .secondary
        case .cancelled, .failed: return .orange
        }
    }

    private func reportStat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.xxSmall) {
            Text(title)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(AppDesign.Typography.bodySemibold)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}
