import SwiftUI
import XCTest
@testable import RunPlayStudio

@MainActor
final class WatchFolderSettingsCommandTests: XCTestCase {
    func testOpeningWatchFolderSettingsSelectsDestinationBeforeOpeningFromAnotherTab() {
        for startingTab in [StudioSettingsTab.athlete, .elevation] {
            var tab = startingTab
            var tabWhenOpened: StudioSettingsTab?
            WorkoutViewCommands.openWatchFolderSettings(
                selection: Binding(get: { tab }, set: { tab = $0 })
            ) {
                tabWhenOpened = tab
            }

            XCTAssertEqual(tabWhenOpened, .watchFolders)
            XCTAssertEqual(tab, .watchFolders)
        }
    }

    /// Each removal button names its folder, so two watched folders do not
    /// share one spoken "Remove Folder" name.
    func testRemoveFolderAccessibilityLabelNamesTheFolderInEveryLanguage() {
        let expected: [(String, String)] = [
            ("en_US", "Remove Long Runs"),
            ("zh-Hans_CN", "移除 Long Runs"),
            ("zh-Hant_TW", "移除 Long Runs"),
        ]
        for (identifier, label) in expected {
            XCTAssertEqual(
                WatchFolderSettingsView.removeFolderAccessibilityLabel(
                    for: "Long Runs",
                    locale: Locale(identifier: identifier)
                ),
                label,
                identifier
            )
        }
        XCTAssertNotEqual(
            WatchFolderSettingsView.removeFolderAccessibilityLabel(for: "Long Runs"),
            WatchFolderSettingsView.removeFolderAccessibilityLabel(for: "Races")
        )
    }
}
