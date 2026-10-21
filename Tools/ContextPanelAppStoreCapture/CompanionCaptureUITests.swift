import XCTest

@MainActor
final class CompanionCaptureUITests: XCTestCase {
    func testNativeFixtureScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "fixture-accessibility-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
        let overview = app.descendants(matching: .any).matching(identifier: "screenshot-overview").firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 90))
        XCTAssertTrue(overview.isHittable)
        if ProcessInfo.processInfo.environment["CP_CAPTURE_DETAIL"] == "true" {
            let studio = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Studio")).firstMatch
            XCTAssertTrue(studio.waitForExistence(timeout: 30))
            studio.tap()
            let detail = app.descendants(matching: .any).matching(identifier: "screenshot-detail").firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 30))
            XCTAssertTrue(detail.isHittable)
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "native-fixture"
        image.lifetime = .keepAlways
        add(image)
    }
}
