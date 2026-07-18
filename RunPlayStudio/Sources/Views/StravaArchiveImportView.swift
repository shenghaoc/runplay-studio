import SwiftUI
import RunPlayCore

/// Sheet for reviewing, importing, and reporting a Strava bulk-export archive.
struct StravaArchiveImportView: View {
    @ObservedObject var session: ArchiveImportSession
    var onImport: () -> Void
    var onCancel: () -> Void
    var onDone: () -> Void
    var onViewImported: () -> Void
    var onOpenHeatmap: () -> Void

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
        .frame(minWidth: 720, minHeight: 480)
        .background(AppDesign.workspaceBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Strava Archive")
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
        .accessibilityLabel("Import Strava Archive, \(session.archiveName)")
    }

    // MARK: - Review

    private var reviewBody: some View {
        VStack(spacing: 0) {
            summaryBar
            filterBar
            candidateTable
            reviewFooter
        }
    }

    private var summaryBar: some View {
        let d = session.scanResult
        return HStack(spacing: AppDesign.Spacing.large) {
            summaryChip("Activities", value: "\(d.candidates.count)")
            summaryChip("Ready", value: "\(d.readyCount)")
            summaryChip("Selected", value: "\(session.selectedCount)")
            summaryChip("Duplicates", value: "\(d.duplicateCount)")
            summaryChip("Other sports", value: "\(d.unsupportedActivityTypeCount)")
            Spacer()
            Text(byteCount(d.diagnostics.estimatedTotalSourceBytes))
                .font(AppDesign.Typography.compactLabel)
                .foregroundStyle(.secondary)
                .help("Estimated total source size of activity files")
        }
        .padding(.horizontal)
        .padding(.vertical, AppDesign.Spacing.medium)
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

    private var filterBar: some View {
        HStack {
            TextField("Search activities", text: $session.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .accessibilityLabel("Search activities")

            Toggle("Running types", isOn: $session.showRunningOnly)
                .toggleStyle(.checkbox)
                .help("Show running and walk/hike candidates")

            Spacer()

            Button("Select All Importable") {
                session.selectAllImportable()
            }
            .help("Select every ready running activity")

            Button("Select None") {
                session.selectNone()
            }
        }
        .padding(.horizontal)
        .padding(.bottom, AppDesign.Spacing.small)
    }

    private var candidateTable: some View {
        Table(session.filteredCandidates) {
            TableColumn("Import") { candidate in
                Toggle(
                    "",
                    isOn: Binding(
                        get: { session.selectedIDs.contains(candidate.id) },
                        set: { isOn in
                            if isOn {
                                session.selectedIDs.insert(candidate.id)
                            } else {
                                session.selectedIDs.remove(candidate.id)
                            }
                        }
                    )
                )
                .labelsHidden()
                .disabled(!candidate.status.isImportableByDefault && candidate.status != .possibleDuplicate)
                .accessibilityLabel("Select \(candidate.displayName)")
            }
            .width(56)

            TableColumn("Date") { candidate in
                Text(dateText(candidate.activityDate))
                    .font(AppDesign.Typography.compactLabel)
            }
            .width(min: 100, ideal: 120)

            TableColumn("Name") { candidate in
                Text(candidate.displayName)
                    .lineLimit(1)
            }
            .width(min: 140, ideal: 220)

            TableColumn("Type") { candidate in
                Text(candidate.activityType ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Format") { candidate in
                Text(candidate.format.displayName)
                    .foregroundStyle(.secondary)
            }
            .width(70)

            TableColumn("Status") { candidate in
                Text(candidate.status.userFacingSummary)
                    .foregroundStyle(statusColor(candidate.status))
                    .help(candidate.statusDetail ?? candidate.status.userFacingSummary)
            }
            .width(min: 120, ideal: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .accessibilityLabel("Archive activity candidates")
    }

    private var reviewFooter: some View {
        HStack {
            if !session.scanResult.diagnostics.warnings.isEmpty {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(session.scanResult.diagnostics.warnings.joined(separator: " "))
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel", action: onCancel)
            Button("Import \(session.selectedCount) Runs") {
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
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)
            .padding(.horizontal, 40)
            .accessibilityLabel("Import progress")
            .accessibilityValue(progressCaption)

            if let name = session.progress.currentFilename {
                Text(name)
                    .font(AppDesign.Typography.compactLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button("Cancel") {
                onCancel()
            }
            .help("Cancel import and leave the library unchanged")
            .disabled(session.progress.phase == .committing)

            Spacer()
        }
    }

    private var progressFraction: Double {
        let total = max(session.progress.totalCount, 1)
        return min(1, Double(session.progress.completedCount) / Double(total))
    }

    private var progressCaption: String {
        let p = session.progress
        return "\(p.completedCount) of \(p.totalCount) · staged \(p.stagedCount) · skipped \(p.skippedCount) · failed \(p.failedCount)"
    }

    // MARK: - Report

    private var reportBody: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.large) {
            if let report = session.report {
                Text(report.commitFailed ? "Import Incomplete" : "Import Complete")
                    .font(AppDesign.Typography.heading2)
                    .padding(.horizontal)
                    .padding(.top)

                if let error = session.errorMessage ?? report.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    reportStat("Imported", report.importedCount)
                    reportStat("Duplicates", report.count(for: .duplicate))
                    reportStat("Other sports", report.count(for: .unsupportedActivityType))
                    reportStat("Unsupported format", report.count(for: .unsupportedFormat))
                    reportStat("No GPS", report.count(for: .noGPSRoute))
                    reportStat("Parse failed", report.count(for: .parseFailed))
                    reportStat("Unsafe entries", report.count(for: .unsafeArchiveEntry))
                    reportStat("Provider conflicts", report.count(for: .providerConflict))
                }
                .padding(.horizontal)

                DisclosureGroup("Details") {
                    List(report.items, id: \.candidateID) { item in
                        HStack {
                            Text(item.activityName ?? item.archiveRelativePath)
                                .lineLimit(1)
                            Spacer()
                            Text(item.status.userFacingSummary)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
                .padding(.horizontal)

                HStack {
                    Spacer()
                    Button("Done", action: onDone)
                        .keyboardShortcut(.defaultAction)
                    if report.importedCount > 0 {
                        Button("View Imported Run", action: onViewImported)
                        Button("Open Personal Heatmap", action: onOpenHeatmap)
                    }
                }
                .padding()
            } else {
                Text("No report available.")
                    .padding()
                Button("Done", action: onDone)
                    .padding()
            }
        }
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
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func phaseLabel(_ phase: WorkoutBatchImportPhase) -> String {
        switch phase {
        case .openingArchive: return "Opening archive…"
        case .readingMetadata: return "Reading metadata…"
        case .scanningEntries: return "Scanning entries…"
        case .awaitingSelection: return "Ready"
        case .importing: return "Importing activities…"
        case .staging: return "Staging workouts…"
        case .committing: return "Saving library…"
        case .completed: return "Complete"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        }
    }

    private func statusColor(_ status: WorkoutArchiveCandidateStatus) -> Color {
        switch status {
        case .ready, .possibleDuplicate: return .primary
        case .duplicate: return .secondary
        case .providerConflict, .parseFailed, .unsafeArchiveEntry, .exceedsResourceLimit:
            return .orange
        case .unsupportedActivityType, .unsupportedFormat, .missingActivityFile, .noGPSRoute, .invalidMetadata:
            return .secondary
        }
    }
}
