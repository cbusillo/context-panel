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
                let account = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", "Work")).firstMatch
                XCTAssertTrue(account.waitForExistence(timeout: 30))
                let attachment = XCTAttachment(screenshot: window.screenshot())
                attachment.name = "mac-\(mode)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
