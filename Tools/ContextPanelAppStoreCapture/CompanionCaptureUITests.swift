import ContextPanelCore
import XCTest

@MainActor
final class CompanionCaptureUITests: XCTestCase {
    func testNativeFixtureScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
        let overview = app.descendants(matching: .any).matching(identifier: "screenshot-overview").firstMatch
        let overviewExists = overview.waitForExistence(timeout: 90)
        recordHierarchy(app, name: "overview")
        XCTAssertTrue(overviewExists)
        XCTAssertTrue(app.frame.intersects(overview.frame))
        let widgetMode = ProcessInfo.processInfo.environment["CP_CAPTURE_WIDGET"] ?? ""
        if !widgetMode.isEmpty {
            try placeFixtureWidget(reusing: widgetMode == "present")
        } else if ProcessInfo.processInfo.environment["CP_CAPTURE_DETAIL"] == "true" {
            let account = try XCTUnwrap(ScreenshotFixture.snapshot.accountOverview(now: ScreenshotFixture.date).accounts.first)
            let prefix = "\(account.metadata.provider.accountDisplayName), \(account.metadata.label),"
            let matches = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            let studio = matches.firstMatch
            XCTAssertTrue(studio.waitForExistence(timeout: 30))
            XCTAssertEqual(matches.count, 1)
            studio.tap()
            let detail = app.descendants(matching: .any).matching(identifier: "screenshot-detail").firstMatch
            let detailExists = detail.waitForExistence(timeout: 30)
            recordHierarchy(app, name: "detail")
            XCTAssertTrue(detailExists)
            XCTAssertTrue(app.frame.intersects(detail.frame))
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
        XCTAssertFalse(home.searchFields.firstMatch.exists)
        XCTAssertFalse(home.buttons["Add Widget"].firstMatch.exists)
        XCTAssertFalse(home.buttons["Done"].firstMatch.exists)
        let account = try XCTUnwrap(ScreenshotFixture.snapshot.accountOverview(now: ScreenshotFixture.date).accounts.first)
        let content = home.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", account.metadata.label)).firstMatch
        let foundContent = content.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-placed")
        XCTAssertTrue(foundContent)
        XCTAssertTrue(home.frame.intersects(content.frame))
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
        let edit = home.buttons["Edit"].firstMatch
        let foundToolbar = edit.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "home-edit")
        XCTAssertTrue(foundToolbar)
        edit.tap()
        let addWidget = home.buttons["Add Widget"].firstMatch
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
        let result = home.buttons["Context Panel"].firstMatch
        let foundResult = result.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-search")
        XCTAssertTrue(foundResult)
        result.tap()
        let add = home.buttons["Add Widget"].firstMatch
        let foundPreview = add.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-preview")
        XCTAssertTrue(foundPreview)
        add.tap()
        let done = home.buttons["Done"].firstMatch
        let foundDone = done.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "widget-added")
        XCTAssertTrue(foundDone)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10))
    }

    private func recordHierarchy(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "fixture-\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
