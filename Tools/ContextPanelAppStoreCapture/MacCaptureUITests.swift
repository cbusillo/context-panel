import ContextPanelCore
import AppKit
import CoreGraphics
import Vision
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
        let baseline = Set(visibleWindows().compactMap { $0[kCGWindowNumber as String] as? Int })
        desktop.rightClick()
        try clickVisibleWidgetMenu(desktop)
        let galleryMatch = try XCTUnwrap(findOwner(stage: "gallery-search", baseline: baseline) { $0.searchFields.firstMatch })
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
        record(gallery, name: "widget-added")
        let done = gallery.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        done.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 15))
        XCTAssertFalse(addWidget.exists)
        XCTAssertFalse(done.exists)
        let labels = ScreenshotFixture.smallWidgetAccountLabels
        let label = try XCTUnwrap(labels.first)
        let predicate = NSPredicate(format: "label == %@", label)
        let widgetHost = try XCTUnwrap(findOwner(stage: "placed-widget", baseline: baseline, interactive: false) {
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
        let screenshot = try waitForWidgetPixels(widget)
        let display = CGMainDisplayID()
        let points = CGDisplayBounds(display).size
        let geometry: [String: Any] = [
            "screenPoints": [points.width, points.height],
            "screenPixels": [CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display)],
            "backingScaleFactor": NSScreen.main?.backingScaleFactor ?? 0,
            "widgetPoints": [widget.frame.minX, widget.frame.minY, widget.frame.maxX, widget.frame.maxY]]
        let data = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
        let metadata = XCTAttachment(string: try XCTUnwrap(String(data: data, encoding: .utf8)))
        metadata.name = "mac-widget-geometry"
        metadata.lifetime = .keepAlways
        add(metadata)
        let image = XCTAttachment(screenshot: screenshot)
        image.name = "mac-widget-desktop"
        image.lifetime = .keepAlways
        add(image)
        app.terminate()
    }

    private func waitForWidgetPixels(_ widget: XCUIElement) throws -> XCUIScreenshot {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            let screenshot = XCUIScreen.main.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let display = CGMainDisplayID()
            XCTAssertEqual(image.width, CGDisplayPixelsWide(display))
            XCTAssertEqual(image.height, CGDisplayPixelsHigh(display))
            let bounds = CGDisplayBounds(display)
            let scale = CGFloat(image.width) / bounds.width
            let crop = widget.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                .applying(CGAffineTransform(scaleX: scale, y: scale))
            let pixels = try XCTUnwrap(image.cropping(to: crop))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: pixels, options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let compact = text.replacingOccurrences(of: " ", with: "").lowercased()
            if ScreenshotFixture.smallWidgetAccountNames.allSatisfy({ compact.contains($0.replacingOccurrences(of: " ", with: "").lowercased()) }) {
                return screenshot
            }
            if Date() >= deadline {
                let evidence = XCTAttachment(screenshot: screenshot)
                evidence.name = "placed-widget-pixel-failure"
                evidence.lifetime = .keepAlways
                add(evidence)
                XCTFail("The desktop widget must render its fixture account names; OCR: \(text)")
                return screenshot
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while true
    }

    private func visibleWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func clickVisibleWidgetMenu(_ desktop: XCUIElement) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let display = CGMainDisplayID()
        XCTAssertEqual(image.width, CGDisplayPixelsWide(display))
        XCTAssertEqual(image.height, CGDisplayPixelsHigh(display))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        let text = observations.compactMap { $0.topCandidates(1).first?.string }
        let metadata = XCTAttachment(string: text.joined(separator: "\n"))
        metadata.name = "native-menu-recognized-text"
        metadata.lifetime = .keepAlways
        add(metadata)
        let frame = XCTAttachment(screenshot: screenshot)
        frame.name = "native-menu"
        frame.lifetime = .keepAlways
        add(frame)
        let matches = observations.filter {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Edit Widgets") == true
        }
        XCTAssertEqual(matches.count, 1)
        let box = try XCTUnwrap(matches.first).boundingBox
        let bounds = CGDisplayBounds(display)
        let point = CGPoint(x: bounds.minX + box.midX * bounds.width,
                            y: bounds.minY + (1 - box.midY) * bounds.height)
        XCTAssertTrue(desktop.frame.contains(point))
        let transform = XCTAttachment(string: "pixels=\(image.width)x\(image.height) displayPoints=\(bounds) OCRBox=\(box) click=\(point)")
        transform.name = "native-menu-pixel-to-point-transform"
        transform.lifetime = .keepAlways
        add(transform)
        desktop.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - desktop.frame.minX, dy: point.y - desktop.frame.minY)).click()
    }

    private func windowHosts(baseline: Set<Int>) -> [(String, XCUIApplication)] {
        var seen = Set<pid_t>()
        return visibleWindows().compactMap { window in
            guard let number = window[kCGWindowNumber as String] as? Int, !baseline.contains(number),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ProcessInfo.processInfo.processIdentifier, seen.insert(pid).inserted,
                  let process = NSRunningApplication(processIdentifier: pid),
                  let url = process.bundleURL, url.pathExtension == "app", !process.isTerminated,
                  process.bundleIdentifier != "com.shinycomputers.contextpanel.screenshots.maccaptureapp" else { return nil }
            return (url.path, XCUIApplication(url: url))
        }
    }

    private func findOwner(stage: String, baseline: Set<Int>, interactive: Bool = true,
                           query: (XCUIApplication) -> XCUIElement)
        -> (identifier: String, app: XCUIApplication, element: XCUIElement)? {
        let processes = NSWorkspace.shared.runningApplications.map {
            "pid=\($0.processIdentifier) policy=\($0.activationPolicy.rawValue) \($0.bundleIdentifier ?? "no identifier") \($0.bundleURL?.path ?? "no URL")"
        }
        let metadata = XCTAttachment(string: processes.joined(separator: "\n") + "\nWindows: \(visibleWindows())")
        metadata.name = stage + "-window-owners-before-query"
        metadata.lifetime = .keepAlways
        add(metadata)
        let initial = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        initial.name = stage + "-before-query"
        initial.lifetime = .keepAlways
        add(initial)
        let deadline = Date().addingTimeInterval(15)
        var hosts: [(String, XCUIApplication)] = []
        var found: (identifier: String, app: XCUIApplication, element: XCUIElement)?
        repeat {
            hosts = windowHosts(baseline: baseline)
            for (identifier, app) in hosts where app.state != .notRunning {
                if Date() >= deadline { break }
                let element = query(app)
                if element.exists && !element.frame.isEmpty && (!interactive || element.isHittable) {
                    found = (identifier, app, element)
                    break
                }
            }
            if found != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        let owner = XCTAttachment(string: "Matched owner: \(found?.identifier ?? "no AX owner")\n" + hosts.map(\.0).joined(separator: "\n") + "\nWindows: \(visibleWindows())")
        owner.name = stage + "-window-owners-after-query"
        owner.lifetime = .keepAlways
        add(owner)
        if let found { record(found.app, name: stage) }
        else {
            for (identifier, app) in hosts where app.state != .notRunning {
                record(app, name: stage + "-" + URL(fileURLWithPath: identifier).lastPathComponent)
            }
        }
        return found
    }

    private func stopOnUnexpectedDialog() {
        addUIInterruptionMonitor(withDescription: "Capture has no permission-grant authority") { alert in
            let photos = alert.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "widget-local:com.apple.Photos:")).firstMatch
            let ordinaryWidget = alert.elementType == .window && alert.title == "Featured"
                && !alert.isEnabled && photos.exists && alert.buttons.count == 0
                && alert.textFields.count == 0 && alert.secureTextFields.count == 0
                && alert.alerts.count == 0 && alert.sheets.count == 0
                && alert.descendants(matching: .dialog).count == 0
            let evidence = XCTAttachment(string: alert.debugDescription)
            evidence.name = ordinaryWidget ? "ordinary-featured-photos-widget" : "unexpected-system-dialog"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            // This is a desktop widget, not an interruption. Claim it so XCTest
            // does not try its Notification Center swipe-to-dismiss handler.
            if ordinaryWidget { return true }
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
