import ContextPanelCore
import AppKit
import CoreGraphics
import XCTest

@MainActor
final class MacCaptureUITests: XCTestCase {
    func testCaptureNativeWidgetPlacement() throws {
        ScreenshotFixture.configureProcess()
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw XCTSkip("Native Mac UI capture requires an isolated GitHub-hosted runner")
        }
        continueAfterFailure = false
        stopOnUnexpectedDialog()
        let app = XCUIApplication()
        app.launchEnvironment = ["GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"]
        app.launchArguments = ["widgets"]
        app.launch()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        record(finder, name: "desktop")
        let desktop = finder.scrollViews["desktop"].firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 15))
        desktop.rightClick()
        let menu = findOwner(stage: "desktop-menu") { $0.menuItems["Edit Widgets…"].firstMatch }
        let menuRoute: String
        if let menu {
            menuRoute = "native AX menu in " + menu.identifier
            menu.element.click()
        } else {
            // The retained native screenshot proves this menu is open, but its
            // owner may expose no AX menu. Use its ordinary keyboard selection.
            menuRoute = "native menu keyboard selection after no AX owner"
            finder.typeKey("e", modifierFlags: [])
            finder.typeKey(.return, modifierFlags: [])
        }
        let galleryMatch = try XCTUnwrap(findOwner(stage: "gallery-search") { $0.searchFields.firstMatch })
        let gallery = galleryMatch.app
        let search = galleryMatch.element
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
        let labels = ScreenshotFixture.smallWidgetAccountLabels
        let label = try XCTUnwrap(labels.first)
        let predicate = NSPredicate(format: "label == %@", label)
        let widgetHost = try XCTUnwrap(findOwner(stage: "placed-widget", interactive: false) {
            $0.descendants(matching: .any).matching(predicate).firstMatch
        }).app
        for label in labels {
            XCTAssertTrue(widgetHost.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch.waitForExistence(timeout: 15))
        }
        record(widgetHost, name: "widget-placed")
        var containers = widgetHost.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Context Panel"))
        for label in labels { containers = containers.containing(NSPredicate(format: "label == %@", label)) }
        let widget = try XCTUnwrap(containers.allElementsBoundByIndex.filter { !$0.frame.isEmpty }
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }))
        let display = CGMainDisplayID()
        let points = CGDisplayBounds(display).size
        let geometry: [String: Any] = [
            "screenPoints": [points.width, points.height],
            "screenPixels": [CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display)],
            "backingScaleFactor": NSScreen.main?.backingScaleFactor ?? 0,
            "menuRoute": menuRoute,
            "widgetPoints": [widget.frame.minX, widget.frame.minY, widget.frame.maxX, widget.frame.maxY]]
        let data = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
        let metadata = XCTAttachment(string: try XCTUnwrap(String(data: data, encoding: .utf8)))
        metadata.name = "mac-widget-geometry"
        metadata.lifetime = .keepAlways
        add(metadata)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "mac-widget-desktop"
        image.lifetime = .keepAlways
        add(image)
        app.terminate()
    }

    private func systemHosts() -> [(String, XCUIApplication)] {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let explicit = ["com.apple.finder", "com.apple.WindowManager", "com.apple.notificationcenterui",
                        "com.apple.dock", "com.apple.controlcenter", "com.apple.systemuiserver"]
        let urls = Set(running.compactMap(\.bundleURL) + explicit.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }).filter { $0.pathExtension == "app" }
        let skipped = running.filter { $0.bundleURL?.pathExtension != "app" }.map {
            "\($0.bundleIdentifier ?? "no bundle identifier"): \($0.bundleURL?.path ?? "no app URL")"
        }
        let evidence = XCTAttachment(string: skipped.sorted().joined(separator: "\n"))
        evidence.name = "non-application-processes"
        evidence.lifetime = .keepAlways
        add(evidence)
        return urls.sorted(by: { $0.path < $1.path }).map { ($0.path, XCUIApplication(url: $0)) }
    }

    private func findOwner(stage: String, interactive: Bool = true,
                           query: (XCUIApplication) -> XCUIElement)
        -> (identifier: String, app: XCUIApplication, element: XCUIElement)? {
        let deadline = Date().addingTimeInterval(15)
        var hosts: [(String, XCUIApplication)] = []
        var found: (identifier: String, app: XCUIApplication, element: XCUIElement)?
        repeat {
            hosts = systemHosts()
            for (identifier, app) in hosts where app.state != .notRunning {
                let element = query(app)
                if element.exists && !element.frame.isEmpty && (!interactive || element.isHittable) {
                    found = (identifier, app, element)
                    break
                }
            }
            if found != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        let owner = XCTAttachment(string: "Matched owner: \(found?.identifier ?? "no AX owner")\n" + hosts.map(\.0).joined(separator: "\n"))
        owner.name = stage + "-system-applications"
        owner.lifetime = .keepAlways
        add(owner)
        for (identifier, app) in hosts where app.state != .notRunning {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = stage + "-" + identifier + "-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = stage + "-screen"
        screen.lifetime = .keepAlways
        add(screen)
        return found
    }

    private func stopOnUnexpectedDialog() {
        addUIInterruptionMonitor(withDescription: "Capture has no permission-grant authority") { alert in
            let evidence = XCTAttachment(string: alert.debugDescription)
            evidence.name = "unexpected-system-dialog"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            XCTFail("Capture stopped at an unexpected system dialog: \(alert.label)")
            return true // Prevent the default interruption handler from dismissing it.
        }
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
        ScreenshotFixture.configureProcess()
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw XCTSkip("Native Mac UI capture requires an isolated GitHub-hosted runner")
        }
        continueAfterFailure = false
        stopOnUnexpectedDialog()
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
