import SwiftUI
import RunPlayCore
import AppKit

/// Toolbar button opening the recent-imports popover. Badge count shows
/// unresolved failures so errors stay glanceable without alerts.
struct RecentImportsToolbarButton: View {
    @ObservedObject var coordinator: WatchFolderCoordinator
    @State private var isPresented = false

    private var failureCount: Int {
        coordinator.recentImports.filter { $0.status == .failed }.count
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label(
                "Recent Imports",
                systemImage: failureCount > 0 ? "tray.2.badge.exclamationmark" : "tray.full"
            )
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RecentImportsPanel(coordinator: coordinator)
                // Keyboard parity: Escape closes the panel the same way a
                // pointer click outside does.
                .onExitCommand { isPresented = false }
        }
        .help("Watch-folder import results")
        .accessibilityLabel(
            failureCount > 0
                ? "Recent imports, \(failureCount) with errors"
                : "Recent imports"
        )
        .accessibilityHint("Shows watch-folder import results with per-file status")
    }
}

/// Toolbar popover listing watch-folder import results, plus the transient
/// non-modal banner for queued multi-session FIT reviews.
///
/// The popover is a lightweight surface: bounded recent rows with per-file
/// success/skip/error and reveal-in-Finder. Errors never raise alerts; they
/// live here as rows. The banner is the only interruption and it, too, is
/// dismissible without acting.
struct RecentImportsPanel: View {
    @ObservedObject var coordinator: WatchFolderCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if coordinator.recentImports.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.recentImports) { record in
                            RecentImportRow(record: record)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Label("Recent Imports", systemImage: "tray.full")
                .font(.headline)
            Spacer()
            if coordinator.isPaused {
                Text("Watching paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No watch-folder imports yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No watch-folder imports yet")
    }
}

/// Transient, non-modal banner shown when a multi-session FIT file is
/// queued for review. Never blocks the window; dismissible without acting.
struct WatchFolderReviewBanner: View {
    @ObservedObject var coordinator: WatchFolderCoordinator
    let onReview: () -> Void

    var body: some View {
        if let banner = coordinator.pendingReviewBanner {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Multi-session FIT ready for review")
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("“\(banner.fileName)” from “\(banner.folderName)” has several sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review…", action: onReview)
                    .accessibilityLabel("Review \(banner.fileName) sessions")
                Button {
                    coordinator.dismissPendingReviewBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss multi-session review banner")
            }
            .padding(10)
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 2, y: 1)
            .padding(.horizontal)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Multi-session FIT file \(banner.fileName) is waiting for review")
            .accessibilityHint("Activate Review to choose which sessions to import, or dismiss to keep it queued")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
