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
        if ProcessInfo.processInfo.environment["CP_CAPTURE_DETAIL"] == "true" {
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

    private func recordHierarchy(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "fixture-\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
