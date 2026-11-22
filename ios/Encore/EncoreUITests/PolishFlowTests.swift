import XCTest

/// Stream ios-polish flows: the "Add to playlist" picker (Saved in, multi-select, Done, New
/// playlist), the like button's "Saved in" path, and the share sheet. Mock core by default;
/// `TEST_RUNNER_ENCORE_LIVE=1` runs `testLivePickerOnRealCore` on the real core (network).
final class PolishFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ links: String, live: Bool = false) {
        app.launchArguments = (live ? ["-volume", "0"] : ["-mock"]) + ["-uitest", "-deeplink", links]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func toastShows(_ text: String, timeout: TimeInterval = 4) -> Bool {
        let t = el("toast")
        guard t.waitForExistence(timeout: timeout) else { return false }
        return t.label.contains(text) || t.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(text) }
    }

    func testPickerShowsSavedInAndAddsToAnotherPlaylist() {
        // Track 4 of LOCALPLAYLIST:1: it is already in that playlist, so it is under "Saved in".
        launch("encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://add-to-playlist")
        XCTAssertTrue(el("add-to-playlist").waitForExistence(timeout: 8))
        let saved = el("picker-row-LOCALPLAYLIST:1")
        XCTAssertTrue(saved.waitForExistence(timeout: 4))
        XCTAssertTrue(saved.isSelected, "the playlist holding the song starts checked")
        XCTAssertTrue(app.staticTexts["Saved in"].exists)

        let unticked = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'picker-row-LOCALPLAYLIST' AND selected == false"))
        XCTAssertGreaterThan(unticked.count, 0)
        let other = unticked.element(boundBy: 0)
        let otherId = other.identifier
        other.tap()
        XCTAssertTrue(el(otherId).isSelected)
        el("picker-done").tap()
        XCTAssertTrue(toastShows("Added to"), "Done adds to the newly ticked playlist")

        // Reopen (the liked song's check in the mini player): it is now under "Saved in" too.
        sleep(2)
        el("mini-like").tap()
        XCTAssertTrue(el("add-to-playlist").waitForExistence(timeout: 6))
        XCTAssertTrue(el(otherId).waitForExistence(timeout: 4))
        XCTAssertTrue(el(otherId).isSelected)
    }

    func testUntickRemovesAndSearchFilters() {
        launch("encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://add-to-playlist")
        XCTAssertTrue(el("add-to-playlist").waitForExistence(timeout: 8))
        let field = app.textFields["Find playlist"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("zzzz-no-such")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'No playlists match'")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Clear search"].tap()
        let saved = el("picker-row-LOCALPLAYLIST:1")
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        saved.tap()
        XCTAssertFalse(saved.isSelected)
        el("picker-done").tap()
        XCTAssertTrue(toastShows("Removed from"))
    }

    func testLikedCheckOpensSavedIn() {
        launch("encore://play/LOCALPLAYLIST:1?index=3&pause=1")
        let like = el("mini-like")
        XCTAssertTrue(like.waitForExistence(timeout: 8))
        if like.label == "Add to Liked Songs" {
            like.tap()
            XCTAssertTrue(toastShows("Liked Songs"))
            // The toast's Change opens the picker.
            el("toast").tap()
        } else {
            like.tap()
        }
        XCTAssertTrue(el("add-to-playlist").waitForExistence(timeout: 6))
        let liked = el("picker-row-VLLM")
        XCTAssertTrue(liked.waitForExistence(timeout: 4))
        XCTAssertTrue(liked.isSelected, "Liked Songs is ticked under Saved in")
    }

    func testNewPlaylistFromPicker() {
        launch("encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://add-to-playlist")
        XCTAssertTrue(el("picker-new-playlist").waitForExistence(timeout: 8))
        el("picker-new-playlist").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Polish Picks")
        alert.buttons["Create"].tap()
        XCTAssertTrue(toastShows("Added to"), "creating from the picker adds the song")
    }

    func testShareSheetFromNowPlaying() {
        launch("encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://nowplaying")
        let share = el("np-share")
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        share.tap()
        // The system share sheet, with our "Copy Chladni link" activity.
        XCTAssertTrue(app.descendants(matching: .any)["Copy Chladni link"].waitForExistence(timeout: 8))
    }

    /// Real core: create a playlist from the picker, then it shows as Saved in.
    func testLivePickerOnRealCore() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCORE_LIVE"] == "1", "live only (TEST_RUNNER_ENCORE_LIVE=1)")
        launch("encore://playsearch?q=daft%20punk%20around%20the%20world", live: true)
        // Wait for the searched track (a relaunch first restores the previous queue).
        let mini = el("mini-player-text")
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !((mini.value as? String ?? "").contains("Around the World")) { sleep(1) }
        let like = el("mini-like")
        XCTAssertTrue(like.waitForExistence(timeout: 5))
        if like.label == "Add to Liked Songs" { like.tap(); sleep(4) }
        like.tap()
        XCTAssertTrue(el("picker-new-playlist").waitForExistence(timeout: 10))
        el("picker-new-playlist").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 4))
        alert.buttons["Create"].tap()
        XCTAssertTrue(toastShows("Added to", timeout: 10))
        sleep(3)
        like.tap()
        XCTAssertTrue(el("add-to-playlist").waitForExistence(timeout: 10))
        let savedIn = app.staticTexts["Saved in"]
        XCTAssertTrue(savedIn.waitForExistence(timeout: 6), "the new playlist holds the song")
        let checked = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'picker-row-LOCALPLAYLIST' AND selected == true"))
        XCTAssertGreaterThan(checked.count, 0)
    }
}
