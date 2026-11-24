import AppKit
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

    // An explicit style lets a hosted layout exercise both AppKit modes
    // without changing the shared system preference.
    var scrollerStyle: NSScroller.Style?
    @State private var preferredScrollerStyle = NSScroller.preferredScrollerStyle
    @State private var presentingScreenWidth: CGFloat?

    var body: some View {
        let keyWindow = NSApp.keyWindow
        let initialScreen = (keyWindow?.sheetParent ?? keyWindow)?.screen ?? NSScreen.main
        let visibleWidth = presentingScreenWidth ?? initialScreen?.visibleFrame.width
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
        .frame(
            minWidth: Column.minimumSheetWidth(
                scrollerStyle: scrollerStyle ?? preferredScrollerStyle,
                visibleFrameWidth: visibleWidth
            ),
            maxWidth: Column.maximumSheetWidth(visibleFrameWidth: visibleWidth),
            minHeight: 480
        )
        .background {
            SheetScreenProbe { presentingScreenWidth = $0 }
        }
        .background(AppDesign.workspaceBackground)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            preferredScrollerStyle = NSScroller.preferredScrollerStyle
        }
    }

    /// Follow the actual presenting window, not whichever display is primary.
    private struct SheetScreenProbe: NSViewRepresentable {
        var reportWidth: (CGFloat) -> Void

        func makeNSView(context: Context) -> ScreenView {
            let view = ScreenView()
            view.reportWidth = reportWidth
            return view
        }

        func updateNSView(_ view: ScreenView, context: Context) {
            view.reportWidth = reportWidth
            view.publishWidth()
        }

        final class ScreenView: NSView {
            var reportWidth: ((CGFloat) -> Void)?
            private var lastWidth: CGFloat?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                NotificationCenter.default.removeObserver(self)
                guard window != nil else { return }
                let center = NotificationCenter.default
                center.addObserver(
                    self, selector: #selector(screenChanged),
                    name: NSWindow.didChangeScreenNotification, object: nil
                )
                center.addObserver(
                    self, selector: #selector(screenChanged),
                    name: NSApplication.didChangeScreenParametersNotification, object: nil
                )
                publishWidth()
            }

            @objc private func screenChanged(_ notification: Notification) {
                if let changedWindow = notification.object as? NSWindow,
                   changedWindow !== window && changedWindow !== window?.sheetParent {
                    return
                }
                publishWidth()
            }

            func publishWidth() {
                guard let width = (window?.sheetParent ?? window)?.screen?.visibleFrame.width,
                      width != lastWidth else { return }
                lastWidth = width
                // SwiftUI may be attaching or updating this representable.
                Task { @MainActor [weak self] in
                    guard let self, self.window != nil, self.lastWidth == width else { return }
                    self.reportWidth?(width)
                }
            }
        }
    }

    private typealias Column = StravaArchiveTableColumn

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
            summaryChip(studioLocalized("Activities"), value: "\(d.candidates.count)")
            summaryChip(studioLocalized("Ready"), value: "\(d.readyCount)")
            summaryChip(studioLocalized("Selected"), value: "\(session.selectedCount)")
            summaryChip(studioLocalized("Duplicates"), value: "\(d.duplicateCount)")
            summaryChip(studioLocalized("Other sports"), value: "\(d.unsupportedActivityTypeCount)")
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
            .width(Column.selection.idealWidth)

            // Date, Type and Status wrap onto a second line rather than
            // truncate when a locale or label is wider than the column.
            TableColumn("Date") { candidate in
                Text(dateText(candidate.activityDate))
                    .font(AppDesign.Typography.compactLabel)
                    .lineLimit(2)
            }
            .width(min: Column.date.minimumWidth, ideal: Column.date.idealWidth)

            TableColumn("Name") { candidate in
                Text(candidate.displayName)
                    .lineLimit(1)
            }
            .width(min: Column.name.minimumWidth, ideal: Column.name.idealWidth)

            TableColumn("Type") { candidate in
                Text(candidate.activityType ?? "—")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .width(min: Column.type.minimumWidth, ideal: Column.type.idealWidth)

            TableColumn("Format") { candidate in
                Text(candidate.format.displayName)
                    .foregroundStyle(.secondary)
            }
            .width(Column.format.idealWidth)

            TableColumn("Status") { candidate in
                Text(candidate.status.userFacingSummary)
                    .lineLimit(2)
                    .foregroundStyle(statusColor(candidate.status))
                    .help(candidate.statusDetail ?? candidate.status.userFacingSummary)
            }
            .width(min: Column.status.minimumWidth, ideal: Column.status.idealWidth)
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
        return studioLocalized("\(p.completedCount) of \(p.totalCount) · staged \(p.stagedCount) · skipped \(p.skippedCount) · failed \(p.failedCount)")
    }

    // MARK: - Report

    private var reportBody: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.large) {
            if let report = session.report {
                Text(BatchImportReportPresentation.archiveTitle(for: report))
                    .font(AppDesign.Typography.heading2)
                    .padding(.horizontal)
                    .padding(.top)

                if let notice = BatchImportReportPresentation.archiveNotice(for: report) {
                    Text(notice)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                }

                if let error = session.errorMessage ?? report.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    reportStat(studioLocalized("Imported"), report.importedCount)
                    reportStat(studioLocalized("Duplicates"), report.count(for: .duplicate))
                    reportStat(studioLocalized("Other sports"), report.count(for: .unsupportedActivityType))
                    reportStat(studioLocalized("Unsupported format"), report.count(for: .unsupportedFormat))
                    reportStat(studioLocalized("No GPS"), report.count(for: .noGPSRoute))
                    reportStat(studioLocalized("Parse failed"), report.count(for: .parseFailed))
                    reportStat(studioLocalized("Unsafe entries"), report.count(for: .unsafeArchiveEntry))
                    reportStat(studioLocalized("Provider conflicts"), report.count(for: .providerConflict))
                }
                .padding(.horizontal)

                if let elevation = BatchImportReportPresentation.archiveElevationSummary(
                    for: report,
                    correctsElevation: session.correctsElevation
                ) {
                    Text(elevation)
                        .font(AppDesign.Typography.compactLabel)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }

                DisclosureGroup("Details") {
                    List(report.items, id: \.candidateID) { item in
                        HStack {
                            Text(item.activityName ?? item.archiveRelativePath)
                                .lineLimit(1)
                            Spacer()
                            if let elevation = BatchImportReportPresentation.archiveItemElevationDetail(
                                item,
                                in: report,
                                correctsElevation: session.correctsElevation
                            ) {
                                Text(elevation)
                                    .foregroundStyle(.secondary)
                            }
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
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func phaseLabel(_ phase: WorkoutBatchImportPhase) -> String {
        switch phase {
        case .openingArchive: return studioLocalized("Opening archive…")
        case .readingMetadata: return studioLocalized("Reading metadata…")
        case .scanningEntries: return studioLocalized("Scanning entries…")
        case .awaitingSelection: return studioLocalized("Ready")
        case .importing: return studioLocalized("Importing activities…")
        case .staging: return studioLocalized("Staging workouts…")
        case .committing: return studioLocalized("Saving library…")
        case .completed: return studioLocalized("Complete")
        case .cancelled: return studioLocalized("Cancelled")
        case .failed: return studioLocalized("Failed")
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
