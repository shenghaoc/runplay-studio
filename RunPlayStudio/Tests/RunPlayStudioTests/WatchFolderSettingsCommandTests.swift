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
}
