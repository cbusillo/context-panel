import ContextPanelCore
import XCTest

@MainActor
final class MacCaptureUITests: XCTestCase {
    func testCaptureNativeFixtureWindows() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw XCTSkip("Native Mac UI capture requires an isolated GitHub-hosted runner")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"]
        for mode in ["overview", "detail"] {
            for appearance in ["light", "dark"] {
                app.launchArguments = [mode, appearance]
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
                let window = app.windows.firstMatch
                XCTAssertTrue(window.waitForExistence(timeout: 30))
                let overview = ScreenshotFixture.snapshot.accountOverview(now: ScreenshotFixture.date)
                let selected = try XCTUnwrap(overview.accounts.first)
                let account: XCUIElement
                if mode == "detail" {
                    account = window.staticTexts.matching(NSPredicate(format: "value == %@", selected.metadata.label)).firstMatch
                } else {
                    let prefix = "\(selected.metadata.provider.accountDisplayName), \(selected.metadata.label),"
                    let rows = window.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
                    account = rows.firstMatch
                    XCTAssertTrue(account.waitForExistence(timeout: 30))
                    XCTAssertEqual(rows.count, 1)
                }
                XCTAssertTrue(account.waitForExistence(timeout: 30))
                XCTAssertTrue(window.frame.contains(account.frame))
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "mac-\(mode)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
