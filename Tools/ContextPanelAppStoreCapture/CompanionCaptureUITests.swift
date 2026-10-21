import ContextPanelCore
import XCTest

@MainActor
final class CompanionCaptureUITests: XCTestCase {
    func testNativeFixtureScreen() throws {
        ScreenshotFixture.configureProcess()
        continueAfterFailure = false
        let app = XCUIApplication()
        let capturesDetail = ProcessInfo.processInfo.environment["CP_CAPTURE_DETAIL"] == "true"
        if capturesDetail { app.launchArguments = ["--screenshot-detail"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
        let identifier = capturesDetail ? "screenshot-detail" : "screenshot-overview"
        let content = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let contentExists = content.waitForExistence(timeout: 90)
        recordHierarchy(app, name: capturesDetail ? "detail" : "overview")
        XCTAssertTrue(contentExists)
        XCTAssertTrue(app.frame.intersects(content.frame))
        let widgetMode = ProcessInfo.processInfo.environment["CP_CAPTURE_WIDGET"] ?? ""
        if !widgetMode.isEmpty {
            try placeFixtureWidget(reusing: widgetMode == "present")
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "native-fixture"
        image.lifetime = .keepAlways
        add(image)
    }

    private func placeFixtureWidget(reusing: Bool) throws {
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        if !reusing { addFixtureWidget(home) }
        XCTAssertFalse(home.searchFields["Search Widgets"].firstMatch.exists)
        XCTAssertFalse(addWidgetButton(home).exists)
        XCTAssertFalse(home.buttons["Done"].firstMatch.exists)
        recordHierarchy(home, name: "widget-placed")
        let labels = ScreenshotFixture.smallWidgetAccountLabels
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            let content = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 30))
            XCTAssertTrue(home.frame.contains(content.frame))
        }
    }

    private func addFixtureWidget(_ home: XCUIApplication) {
        let icon = home.icons["Context Panel"].firstMatch
        let foundIcon = icon.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "home")
        XCTAssertTrue(foundIcon)
        icon.press(forDuration: 2)
        let editHome = home.buttons["Edit Home Screen"]
        let foundEdit = editHome.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "home-menu")
        XCTAssertTrue(foundEdit)
        editHome.tap()
        home.swipeRight() // Return from the fixture's page to the first Home Screen page.
        let edit = home.buttons["Edit"].firstMatch
        let foundToolbar = edit.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "home-edit")
        XCTAssertTrue(foundToolbar)
        edit.tap()
        let addWidget = addWidgetButton(home)
        let foundAdd = addWidget.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "edit-menu")
        XCTAssertTrue(foundAdd)
        addWidget.tap()
        let search = home.searchFields.firstMatch
        let foundSearch = search.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-gallery")
        XCTAssertTrue(foundSearch)
        search.tap()
        search.typeText("Context Panel")
        let result = home.cells["Context Panel"].firstMatch
        let foundResult = result.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-search")
        XCTAssertTrue(foundResult)
        result.tap()
        let add = addWidgetButton(home)
        let foundPreview = add.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-preview")
        XCTAssertTrue(foundPreview)
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 15))
        let done = home.buttons["Done"].firstMatch
        let foundDone = done.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "widget-added")
        XCTAssertTrue(foundDone)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
    }

    private func addWidgetButton(_ home: XCUIApplication) -> XCUIElement {
        home.buttons.matching(NSPredicate(format: "label MATCHES %@", #"^\s*Add Widget\s*$"#)).firstMatch
    }

    private func recordHierarchy(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "fixture-\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
