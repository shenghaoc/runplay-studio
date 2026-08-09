import AppKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI
import UniformTypeIdentifiers

/// Configuration sheet for deterministic offline comparison-replay MP4 export.
struct ComparisonVideoExportSheet: View {
    @Bindable var viewModel: ComparisonVideoExportViewModel
    var onDismiss: () -> Void
    var onExported: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                controls
                    .frame(width: 320, alignment: .topLeading)
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(minWidth: 960, minHeight: 660)
        .task {
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.dismissCleanup()
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            if newPhase == .completed, let name = viewModel.lastExportedFilename {
                onExported(name)
                onDismiss()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Comparison Replay")
                    .font(.title2.weight(.semibold))
                Text("P \(viewModel.pair.primary.displayName)  vs  C \(viewModel.pair.comparison.displayName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(viewModel.outputSummaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var controls: some View {
        Form {
            Section("Video Length") {
                Picker("Video Length", selection: $viewModel.configuration.duration) {
                    ForEach(WorkoutVideoDuration.allCases, id: \.self) { duration in
                        Text("\(duration.seconds) sec")
                            .accessibilityLabel(duration.displayName)
                            .tag(duration)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.isExporting)
                .accessibilityLabel("Video length")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $viewModel.configuration.appearance) {
                    ForEach(PNGSummaryExportAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.isExporting)
                .accessibilityLabel("Export appearance")
            }

            Section("Alignment") {
                Picker("Alignment", selection: $viewModel.configuration.alignmentMode) {
                    ForEach(ComparisonAlignmentMode.allCases, id: \.self) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                            .disabled(!viewModel.isAlignmentModeEnabled(mode) && mode == .routeAware)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.isExporting)
                .accessibilityLabel("Comparison alignment mode")
                .accessibilityValue(viewModel.configuration.alignmentMode.displayName)
                .accessibilityHint(viewModel.alignmentHelpText)

                Text(viewModel.alignmentHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(viewModel.alignmentHelpText)

                if viewModel.configuration.alignmentMode == .routeAware,
                   !viewModel.isRouteAwareAvailable,
                   !viewModel.isPreparingAlignment {
                    Button("Use Distance Alignment") {
                        viewModel.useDistanceAlignment()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Switch to distance-based comparison video when route-aware alignment cannot be used")
                    .accessibilityLabel("Use Distance Alignment")
                }
            }

            Section("Output") {
                LabeledContent("Container", value: "MP4")
                LabeledContent("Codec", value: "H.264")
                LabeledContent("Resolution", value: viewModel.outputResolutionText)
                LabeledContent("Frame rate", value: viewModel.outputFrameRateText)
                LabeledContent("Audio", value: "None")
                LabeledContent("Primary", value: "P · Blue")
                LabeledContent("Comparison", value: "C · Orange")
            }

            if let mapFailure = viewModel.mapFailureMessage {
                Section("Map unavailable") {
                    Text(mapFailure)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        viewModel.retryMap()
                    }
                    .disabled(viewModel.isExporting)
                }
            }

            if let error = viewModel.errorMessage {
                Section(viewModel.isPreviewFailure ? "Preview failed" : "Export failed") {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if viewModel.isPreviewFailure {
                        Button("Retry Preview") {
                            viewModel.retryPreview()
                        }
                        .disabled(!viewModel.canRetryPreview)
                    } else {
                        Button("Try Again…") {
                            presentSavePanel()
                        }
                        .disabled(!viewModel.canExport)
                    }
                }
            }

            Section {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        if viewModel.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(statusAccessibilityLabel)

                if viewModel.isExporting, viewModel.progress.totalFrames > 0 {
                    ProgressView(
                        value: Double(viewModel.progress.completedFrames),
                        total: Double(viewModel.progress.totalFrames)
                    )
                    .accessibilityLabel("Encoding comparison video")
                    .accessibilityValue(
                        "\(viewModel.progress.completedFrames) of \(viewModel.progress.totalFrames) frames, \(viewModel.progress.percentComplete) percent"
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if let image = viewModel.posterImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(viewModel.posterAccessibilityLabel)
                } else if viewModel.isPreparingPoster || viewModel.isPreparingAlignment {
                    ProgressView("Preparing preview…")
                } else if viewModel.phase == .alignmentUnavailable {
                    ContentUnavailableView(
                        "Route-Aware unavailable",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text(viewModel.alignmentHelpText)
                    )
                } else {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "film",
                        description: Text("Adjust settings or retry map preparation.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                viewModel.cancel()
                if !viewModel.isExporting {
                    onDismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
            .disabled(viewModel.isCancelling)

            Spacer()

            if viewModel.isExporting {
                Button("Cancel Export") {
                    viewModel.cancelExport()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isCancelling)
            } else {
                Button("Export Comparison Video…") {
                    presentSavePanel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canExport)
                .accessibilityLabel("Export comparison replay as MP4 video")
            }
        }
        .padding(20)
    }

    private var statusText: String {
        if viewModel.isCancelling { return "Cancelling…" }
        if viewModel.isExporting {
            if viewModel.progress.totalFrames > 0 {
                return "Encoding \(viewModel.progress.completedFrames)/\(viewModel.progress.totalFrames)"
            }
            return viewModel.phase.displayName
        }
        if viewModel.isPreparingAlignment { return "Aligning routes…" }
        if viewModel.isPreparingPoster { return "Preparing preview…" }
        if viewModel.canExport { return "Ready to export" }
        return viewModel.phase.displayName
    }

    private var statusAccessibilityLabel: String {
        if viewModel.isExporting, viewModel.progress.totalFrames > 0 {
            return "Encoding comparison video, \(viewModel.progress.percentComplete) percent complete"
        }
        return statusText
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = viewModel.defaultFilename()
        panel.title = "Export Comparison Replay"
        panel.message = "Choose where to save the comparison MP4 video."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await viewModel.export(to: url)
        }
    }
}
