import SwiftUI
import RunPlayCore

/// Sheet for reviewing, importing, and reporting the sessions inside one
/// multi-session FIT file.
///
/// Mirrors the Strava archive sheet's structure so keyboard handling, modal
/// command blocking, and the cancel/dismiss lifecycle behave identically.
struct FITSessionImportView: View {
    @ObservedObject var session: FITSessionImportSession
    var onImport: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void
    var onViewImported: () -> Void
    var onOpenAllRuns: () -> Void

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
        .frame(minWidth: 940, minHeight: 480)
        .background(AppDesign.workspaceBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import FIT Sessions")
                    .font(AppDesign.Typography.heading2)
                Text(session.fileName)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if session.phase == .reviewing {
                Button("Cancel", action: onCancel)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Import FIT Sessions, \(session.fileName)")
    }

    // MARK: - Review

    private var reviewBody: some View {
        VStack(spacing: 0) {
            summaryBar
            selectionBar
            candidateTable
            reviewFooter
        }
    }

    private var summaryBar: some View {
        let result = session.scanResult
        return HStack(spacing: AppDesign.Spacing.large) {
            summaryChip("Sessions", value: "\(result.candidates.count)")
            summaryChip("Importable", value: "\(result.readyCount)")
            summaryChip("Selected", value: "\(session.selectedCount)")
            summaryChip("Already imported", value: "\(result.duplicateCount)")
            summaryChip("Unsupported", value: "\(result.unsupportedCount)")
            summaryChip("Ambiguous", value: "\(result.ambiguousCount)")
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, AppDesign.Spacing.medium)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session summary")
    }

    private func summaryChip(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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

    private var selectionBar: some View {
        HStack {
            Text(session.selectionAccessibilityValue)
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Select All Importable") {
                session.selectAllImportable()
            }
            .help("Select every session that is ready to import")
            .disabled(session.scanResult.readyCount == 0)

            Button("Select None") {
                session.selectNone()
            }
            .disabled(session.selectedCount == 0)
        }
        .padding(.horizontal)
        .padding(.bottom, AppDesign.Spacing.small)
        .accessibilityValue(session.selectionAccessibilityValue)
    }

    private var candidateTable: some View {
        Table(session.displayedCandidates) {
            TableColumn("Include") { candidate in
                Toggle(
                    "",
                    isOn: Binding(
                        get: { session.isSelected(candidate) },
                        set: { session.setSelected($0, for: candidate) }
                    )
                )
                .labelsHidden()
                .disabled(!session.isSelectable(candidate))
                .accessibilityLabel("Import \(candidate.displayName)")
                .accessibilityValue(session.isSelected(candidate) ? "Selected" : "Not selected")
                .accessibilityHint(
                    session.isSelectable(candidate)
                        ? "Include this session in the import"
                        : candidate.statusDetail ?? candidate.status.userFacingSummary
                )
            }
            .width(58)

            TableColumn("Session") { candidate in
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.displayName)
                        .lineLimit(1)
                    if let subSport = candidate.subSportDescription {
                        Text(subSport)
                            .font(AppDesign.Typography.compactLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.accessibilityLabel(for: candidate))
            }
            .width(min: 150, ideal: 172)

            TableColumn("Date") { candidate in
                Text(dateText(candidate.startDate))
                    .font(AppDesign.Typography.compactLabel)
                    .monospacedDigit()
            }
            .width(min: 105, ideal: 116)

            TableColumn("Sport") { candidate in
                Text(candidate.sportDescription)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 78)

            TableColumn("Elapsed") { candidate in
                Text(DisplayFormatter.formatDuration(candidate.elapsedSeconds))
                    .monospacedDigit()
            }
            .width(min: 62, ideal: 68)

            TableColumn("Distance") { candidate in
                Text(DisplayFormatter.formatDistance(candidate.reportedDistanceMeters))
                    .monospacedDigit()
            }
            .width(min: 66, ideal: 72)

            TableColumn("GPS Points") { candidate in
                Text("\(candidate.gpsRecordCount)")
                    .monospacedDigit()
            }
            .width(min: 74, ideal: 80)

            TableColumn("Laps") { candidate in
                Text("\(candidate.recordedLapCount)")
                    .monospacedDigit()
            }
            .width(46)

            TableColumn("Status") { candidate in
                // Status is conveyed by text; colour is only reinforcement.
                Text(candidate.status.userFacingSummary)
                    .foregroundStyle(statusColor(candidate.status))
                    .help(candidate.statusDetail ?? candidate.status.userFacingSummary)
                    .accessibilityLabel(
                        "\(candidate.status.userFacingSummary). \(candidate.statusDetail ?? "")"
                    )
            }
            .width(min: 120, ideal: 138)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("FIT sessions in \(session.fileName)")
    }

    private var reviewFooter: some View {
        HStack {
            if !session.scanResult.warnings.isEmpty {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(session.scanResult.warnings.joined(separator: " "))
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(importButtonTitle) {
                onImport()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!session.canImport)
            .buttonStyle(.borderedProminent)
            .accessibilityValue(session.selectionAccessibilityValue)
        }
        .padding()
    }

    private var importButtonTitle: String {
        session.selectedCount == 1 ? "Import 1 Run" : "Import \(session.selectedCount) Runs"
    }

    // MARK: - Progress

    private var progressBody: some View {
        VStack(spacing: AppDesign.Spacing.xxxLarge) {
            Spacer()
            progressIndicator
                .frame(maxWidth: 420)
                .padding(.horizontal, 40)
                .accessibilityLabel("FIT session import progress")
                .accessibilityValue(progressCaption)

            if let name = session.progress.currentFilename {
                Text(name)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Cancel", action: onCancel)
                .help("Cancel the import and leave the library unchanged")
                .keyboardShortcut(.cancelAction)
                .disabled(session.progress.phase == .committing)

            Spacer()
        }
    }

    /// Only shows a determinate bar once the total is actually known; a
    /// percentage is never invented for unmeasurable work.
    @ViewBuilder
    private var progressIndicator: some View {
        if session.progress.totalCount > 0 {
            ProgressView(value: progressFraction) {
                Text(phaseLabel)
                    .font(AppDesign.Typography.bodySemibold)
            } currentValueLabel: {
                Text(progressCaption)
                    .font(AppDesign.Typography.secondary)
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
        } else {
            ProgressView {
                Text(phaseLabel)
                    .font(AppDesign.Typography.bodySemibold)
            }
        }
    }

    private var progressFraction: Double {
        let total = max(session.progress.totalCount, 1)
        return min(1, Double(session.progress.completedCount) / Double(total))
    }

    private var progressCaption: String {
        let progress = session.progress
        if progress.totalCount == 0 {
            return phaseLabel
        }
        return "Session \(progress.completedCount) of \(progress.totalCount)"
            + " · staged \(progress.stagedCount)"
            + " · skipped \(progress.skippedCount)"
            + " · failed \(progress.failedCount)"
    }

    private var phaseLabel: String {
        switch session.progress.phase {
        case .openingArchive: return "Reading FIT file…"
        case .readingMetadata: return "Reading FIT file…"
        case .scanningEntries: return "Scanning sessions…"
        case .awaitingSelection: return "Ready"
        case .importing: return "Importing sessions…"
        case .staging: return "Staging workouts…"
        case .committing: return "Saving library…"
        case .completed: return "Complete"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    // MARK: - Report

    private var reportBody: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.large) {
            if let report = session.report {
                Text(reportTitle(for: report))
                    .font(AppDesign.Typography.heading2)
                    .padding(.horizontal)
                    .padding(.top)

                if let error = session.errorMessage ?? report.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .accessibilityLabel("Import error: \(error)")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    reportStat("Imported", report.importedCount)
                    reportStat("Already imported", report.count(for: .duplicate))
                    reportStat("Unsupported", report.count(for: .unsupportedSport))
                    reportStat("No GPS", report.count(for: .noGPSRoute))
                    reportStat("Ambiguous", report.count(for: .ambiguousAttribution))
                    reportStat("Missing boundaries", report.count(for: .invalidBoundaries))
                    reportStat("Over limit", report.count(for: .exceedsResourceLimit))
                    reportStat("Failed", report.count(for: .parseFailed))
                }
                .padding(.horizontal)

                DisclosureGroup("Details") {
                    List(report.items, id: \.candidateID) { item in
                        HStack {
                            Text(item.sessionName)
                                .lineLimit(1)
                            Spacer()
                            Text(itemStatusText(item, commitFailed: report.commitFailed))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(item.sessionName), "
                                + itemStatusText(item, commitFailed: report.commitFailed)
                                + (item.detail.map { ". \($0)" } ?? "")
                        )
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
                .padding(.horizontal)

                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                    if report.importedCount > 0 {
                        Button("Open Imported Run", action: onViewImported)
                        Button("Open All Runs", action: onOpenAllRuns)
                    }
                }
                .padding()
            } else {
                Text("No report available.")
                    .padding()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .padding()
            }
        }
    }

    private func reportTitle(for report: FITSessionBatchImportReport) -> String {
        if report.commitFailed { return "Import Failed" }
        if report.wasCancelled { return "Import Cancelled" }
        return "Import Complete"
    }

    /// A staged session whose commit failed was never imported; say so.
    private func itemStatusText(
        _ item: FITSessionImportItemResult,
        commitFailed: Bool
    ) -> String {
        if item.status == .ready {
            return commitFailed ? "Not saved" : "Imported"
        }
        return item.status.userFacingSummary
    }

    private func reportStat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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

    // MARK: - Helpers

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func statusColor(_ status: FITSessionCandidateStatus) -> Color {
        switch status {
        case .ready: return .primary
        case .duplicate, .unsupportedSport, .noGPSRoute: return .secondary
        case .invalidBoundaries, .ambiguousAttribution, .exceedsResourceLimit, .parseFailed:
            return .orange
        }
    }
}
