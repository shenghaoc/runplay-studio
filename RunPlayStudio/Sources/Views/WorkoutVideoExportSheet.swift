import AppKit
import RunPlayCore
import RunPlayPlatform
import SwiftUI
import UniformTypeIdentifiers

/// Configuration sheet for deterministic offline route-replay MP4 export.
struct WorkoutVideoExportSheet: View {
    @Bindable var viewModel: WorkoutVideoExportViewModel
    var onDismiss: () -> Void
    var onExported: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                controls
                    .frame(width: 300, alignment: .topLeading)
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 640)
        .task {
            viewModel.onAppear()
            await viewModel.updateAvailabilityProbe()
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Export Route Replay")
                    .font(.title2.weight(.semibold))
                Text(viewModel.outputSummaryText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
                .accessibilityHint("Compresses the full workout elapsed timeline into the selected length")
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

            Section("Route Color") {
                Picker("Route Color", selection: $viewModel.configuration.routeColorMode) {
                    ForEach(WorkoutRouteColorMode.allCases, id: \.self) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                            .disabled(!viewModel.isModeAvailable(mode))
                    }
                }
                .disabled(viewModel.isExporting || viewModel.isLoadingAvailability)
                .accessibilityLabel("Route color mode")

                if viewModel.isLoadingAvailability {
                    Text("Checking metric availability…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(
                        WorkoutRouteColorMode.allCases.filter { $0 != .solid },
                        id: \.self
                    ) { mode in
                        if !viewModel.isModeAvailable(mode) {
                            Text("\(mode.displayName): \(mode.unavailableReason ?? "Unavailable")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section("Output") {
                LabeledContent("Container", value: "MP4")
                LabeledContent("Codec", value: "H.264")
                LabeledContent("Resolution", value: viewModel.outputResolutionText)
                LabeledContent("Frame rate", value: viewModel.outputFrameRateText)
                LabeledContent("Audio", value: "None")
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
                    .accessibilityLabel("Encoding video")
                    .accessibilityValue(
                        "\(viewModel.progress.completedFrames) of \(viewModel.progress.totalFrames) frames, \(viewModel.progress.percentComplete) percent"
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Poster Preview")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))

                if let image = viewModel.posterImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                        .opacity(viewModel.isPreparingPoster ? 0.55 : 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(viewModel.posterAccessibilityLabel)
                } else if viewModel.isPreparingPoster {
                    ProgressView("Preparing map and preview…")
                } else if viewModel.mapFailureMessage != nil {
                    Text("Map preview unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Preview will appear here")
                        .foregroundStyle(.secondary)
                }

                if viewModel.isPreparingPoster, viewModel.posterImage != nil {
                    ProgressView()
                        .controlSize(.regular)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )

            Text("Final output: \(viewModel.outputResolutionText) H.264 MP4 · source elapsed timeline compressed to \(viewModel.configuration.duration.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if viewModel.isExporting {
                Button("Cancel Export") {
                    viewModel.cancelExport()
                }
                .disabled(viewModel.isCancelling)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel video export")
            } else {
                Button("Cancel") {
                    viewModel.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button("Export Video…") {
                presentSavePanel()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canExport)
            .accessibilityLabel("Export video")
            .accessibilityHint("Chooses a destination and encodes the offline route replay MP4")
        }
        .padding(20)
    }

    private var statusText: String {
        if viewModel.isCancelling {
            return WorkoutVideoExportPhase.cancelling.displayName
        }
        if viewModel.isExporting, viewModel.progress.totalFrames > 0 {
            return "\(viewModel.phase.displayName) · \(viewModel.progress.completedFrames)/\(viewModel.progress.totalFrames)"
        }
        return viewModel.phase.displayName
    }

    private var statusAccessibilityLabel: String {
        if viewModel.isCancelling {
            return "Cancelling video export and removing temporary output"
        }
        if viewModel.isExporting, viewModel.progress.totalFrames > 0 {
            return "Encoding video \(viewModel.progress.completedFrames) of \(viewModel.progress.totalFrames) frames, \(viewModel.progress.percentComplete) percent complete"
        }
        return "Export status \(viewModel.phase.displayName)"
    }

    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = viewModel.defaultFilename()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.title = "Export Route Replay"
        panel.message = "Save the offline H.264 MP4. Map imagery may have contacted Apple; the file stays on this Mac."

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await viewModel.export(to: url)
            }
        }
    }
}
