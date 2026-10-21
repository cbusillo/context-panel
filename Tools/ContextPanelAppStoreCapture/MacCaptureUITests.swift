import ContextPanelCore
import AppKit
import XCTest

@MainActor
final class MacCaptureUITests: XCTestCase {
    func testCaptureNativeWidgetPlacement() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw XCTSkip("Native Mac UI capture requires an isolated GitHub-hosted runner")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"]
        app.launchArguments = ["widgets", "dark"]
        app.launch()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        record(finder, name: "desktop")
        finder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let edit = finder.menuItems.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit Widgets")).firstMatch
        let foundEdit = edit.waitForExistence(timeout: 15)
        record(finder, name: "desktop-menu")
        XCTAssertTrue(foundEdit)
        edit.click()
        let hosts = [("finder", finder), ("notificationcenter", XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")),
                     ("dock", XCUIApplication(bundleIdentifier: "com.apple.dock")), ("controlcenter", XCUIApplication(bundleIdentifier: "com.apple.controlcenter"))]
        for (name, host) in hosts where host.state != .notRunning { record(host, name: "gallery-host-\(name)") }
        let running = XCTAttachment(string: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).sorted().joined(separator: "\n"))
        running.name = "hosted-system-applications"
        running.lifetime = .keepAlways
        add(running)
        let gallery = try XCTUnwrap(hosts.map(\.1).first(where: { $0.searchFields.firstMatch.waitForExistence(timeout: 10) }))
        let search = gallery.searchFields.firstMatch
        search.click()
        search.typeText("Context Panel")
        record(gallery, name: "widget-search")
        let result = gallery.buttons["Context Panel"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        result.click()
        record(gallery, name: "widget-preview")
        let addWidget = gallery.buttons["Add Widget"].firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 15))
        addWidget.click()
        let done = gallery.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        done.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 15))
        let account = try XCTUnwrap(ScreenshotFixture.snapshot.accountOverview(now: ScreenshotFixture.date).accounts.first)
        let predicate = NSPredicate(format: "label CONTAINS %@", account.metadata.label)
        let widgetHost = try XCTUnwrap(hosts.map(\.1).first(where: {
            $0.descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: 10)
        }))
        let content = widgetHost.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1440, height: 900).contains(content.frame))
        record(finder, name: "widget-placed")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "mac-widget-desktop"
        image.lifetime = .keepAlways
        add(image)
        app.terminate()
    }

    private func record(_ app: XCUIApplication, name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name + "-screen"
        screen.lifetime = .keepAlways
        add(screen)
    }

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
