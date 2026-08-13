import XCTest

final class FireProspectUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testSidebarNavigatesToEveryDestination() {
        let sidebar = app.descendants(matching: .any)["sidebar.navigation"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "The navigation sidebar should be visible after launch.")

        assertDestination("home", label: "Home", detailIdentifier: "detail.home")
        assertDestination("search", label: "New Search", detailIdentifier: "detail.search")
        assertDestination("searches", label: "Searches", detailIdentifier: "detail.prospects")
        assertDestination("settings", label: "Settings", detailIdentifier: "detail.settings")
    }

    func testSidebarDestinationsExposeReadableAccessibilityLabels() {
        for (destination, identifier) in [("Home", "home"), ("New Search", "search"), ("Searches", "searches"), ("Settings", "settings")] {
            let row = app.descendants(matching: .any)["sidebar.destination.\(identifier)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertEqual(row.label, destination)
            XCTAssertTrue(row.isHittable, "\(destination) should remain an actionable standard sidebar row.")
        }
    }

    func testSidebarLabelsAtAccessibilityTextSize() {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["UI_TEST_ACCESSIBILITY_TEXT_SIZE"] = "1"
        app.launch()

        for destination in ["home", "search", "searches", "settings"] {
            let row = app.descendants(matching: .any)["sidebar.destination.\(destination)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.isHittable, "\(destination) should remain readable and actionable at an accessibility text size.")
        }
    }

    func testKeyboardCommandsSwitchDestinations() {
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["detail.prospects"].waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["detail.settings"].waitForExistence(timeout: 5))

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["detail.search"].waitForExistence(timeout: 5))

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["detail.home"].waitForExistence(timeout: 5))
    }

    private func assertDestination(_ identifier: String, label: String, detailIdentifier: String) {
        let row = app.descendants(matching: .any)["sidebar.destination.\(identifier)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, label)
        row.click()
        XCTAssertTrue(app.descendants(matching: .any)[detailIdentifier].waitForExistence(timeout: 5))
    }
}
