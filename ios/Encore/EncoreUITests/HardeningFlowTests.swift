import XCTest

/// Lane P3: the core-failed screen (never the fixtures) and a refused action that says so instead
/// of a false "Added". Debug-only launch arguments: `-coreFail`, and `-fail <actions>` on the mock.
final class HardeningFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    func testCoreFailureShowsTheErrorScreen() {
        app.launchArguments = ["-uitest", "-coreFail"]
        app.launch()
        XCTAssertTrue(el("core-failed").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Chladni couldn't start"].exists)
        XCTAssertTrue(el("core-diagnostics").exists, "Send diagnostics")
        XCTAssertTrue(el("core-copy-log").exists)
        XCTAssertFalse(el("tab-home").exists, "no fixture library behind it")
        el("core-retry").tap()
        // Still failing (-coreFail): the screen stays, ready for another try.
        XCTAssertTrue(el("core-retry").waitForExistence(timeout: 5))
        XCTAssertTrue(el("core-failed").exists)
    }

    func testRefusedAddToPlaylistSaysSo() {
        app.launchArguments = ["-mock", "-uitest", "-fail", "addToPlaylist",
                               "-deeplink", "encore://play/LOCALPLAYLIST:1?index=3&pause=1 encore://add-to-playlist"]
        app.launch()
        XCTAssertTrue(el("add-to-playlist").waitForExistence(timeout: 8))
        let unticked = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'picker-row-LOCALPLAYLIST' AND selected == false"))
        XCTAssertTrue(unticked.element(boundBy: 0).waitForExistence(timeout: 4))
        unticked.element(boundBy: 0).tap()
        el("picker-done").tap()
        let toast = el("toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        let text = ([toast.label] + toast.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        XCTAssertTrue(text.contains("Couldn't add to"), "got: \(text)")
        XCTAssertFalse(text.contains("Added to"), "no false Added: \(text)")
    }
}
