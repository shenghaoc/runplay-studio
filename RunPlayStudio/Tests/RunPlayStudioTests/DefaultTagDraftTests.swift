import XCTest
import RunPlayCore
@testable import RunPlayStudio

/// Staged editing of a watch folder's default tag (#183).
final class DefaultTagDraftTests: XCTestCase {

    func testTypingDoesNotChangeTheCommittedTag() {
        var draft = DefaultTagDraft(committed: "watch")
        draft.text = "wat"
        XCTAssertEqual(draft.committed, "watch")
        XCTAssertNil(draft.pendingCommit, "no write happens until the edit is committed")
    }

    func testCommitNormalisesAndReturnsTheValueToPersist() {
        var draft = DefaultTagDraft(committed: "watch")
        draft.text = "\t  Garmin \n"
        XCTAssertEqual(draft.commit(), "Garmin")
        XCTAssertEqual(draft.committed, "Garmin")
        XCTAssertEqual(draft.text, "Garmin", "the field shows what was stored")
    }

    func testBlankInputCommitsNoTag() {
        var draft = DefaultTagDraft(committed: "watch")
        draft.text = "  \t "
        XCTAssertEqual(draft.commit(), "")
        XCTAssertEqual(draft.committed, "")
    }

    func testCommitWithoutAChangeWritesNothing() {
        var draft = DefaultTagDraft(committed: "watch")
        draft.text = "  watch "
        XCTAssertNil(draft.commit(), "an edit that normalises to the stored tag is not persisted again")
    }

    func testDiscardRestoresTheCommittedTag() {
        var draft = DefaultTagDraft(committed: "watch")
        draft.text = "oops"
        draft.discard()
        XCTAssertEqual(draft.text, "watch")
        XCTAssertNil(draft.commit())
        XCTAssertEqual(draft.committed, "watch")
    }

    func testAnExternalChangeUpdatesAnUntouchedDraft() {
        var draft = DefaultTagDraft(committed: "watch")
        draft.committedExternally("other")
        XCTAssertEqual(draft.text, "other")
    }
}
