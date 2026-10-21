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
        app.launchEnvironment = environment.filter { ["GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"].contains($0.key) }
        app.launchArguments = ["widgets"]
        app.launch()
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        record(finder, name: "desktop")
        let desktop = finder.scrollViews["desktop"].firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 15))
        let reference = finder.menuBars.firstMatch
        XCTAssertTrue(reference.waitForExistence(timeout: 15))
        let center = CGPoint(x: desktop.frame.midX, y: desktop.frame.midY)
        let stockWidgets = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui").windows
            .containing(NSPredicate(format: "identifier BEGINSWITH %@", "widget-local:"))
        for window in stockWidgets.allElementsBoundByIndex {
            XCTAssertFalse(window.frame.contains(center), "The desktop click must avoid native widget windows")
            XCTAssertFalse(window.frame.intersects(reference.frame), "The coordinate reference must avoid native widget windows")
        }
        let originalStockCount = stockWidgets.count
        let baseline = Set(visibleWindows().compactMap { $0[kCGWindowNumber as String] as? Int })
        nativeCoordinate(center, relativeTo: reference).rightClick()
        try clickVisibleWidgetMenu(desktop, reference: reference)
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
        let done = gallery.buttons["widget-add-sheet-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        // Notification Center also exposes its full-screen overlay as a dialog.
        // Scope the gallery to the native controls without the menu-bar overlay.
        let sheets = gallery.descendants(matching: .dialog).allElementsBoundByIndex
            .filter {
                $0.frame.contains(search.frame) && $0.frame.contains(done.frame)
                    && !$0.frame.intersects(reference.frame)
            }
        XCTAssertEqual(sheets.count, 1)
        let sheetFrame = try XCTUnwrap(sheets.first).frame
        XCTAssertFalse(reference.frame.intersects(sheetFrame))
        let editableStocks = gallery.groups.matching(NSPredicate(format: "identifier BEGINSWITH %@", "widget-local:"))
        let stockIDs = editableStocks.allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(stockIDs.count, originalStockCount)
        XCTAssertEqual(Set(stockIDs).count, stockIDs.count)
        for (index, identifier) in stockIDs.enumerated() {
            let stock = gallery.groups.matching(identifier: identifier).firstMatch
            let remove = stock.buttons["minus"].firstMatch
            _ = remove.waitForExistence(timeout: 10)
            record(gallery, name: "stock-before-removal-" + stock.label)
            XCTAssertTrue(remove.exists)
            let point = CGPoint(x: remove.frame.midX, y: remove.frame.midY)
            XCTAssertTrue(stock.frame.contains(point))
            XCTAssertFalse(sheetFrame.contains(point))
            nativeCoordinate(point, relativeTo: reference).click()
            XCTAssertTrue(stock.waitForNonExistence(timeout: 10))
            XCTAssertEqual(editableStocks.count, stockIDs.count - index - 1)
        }
        XCTAssertEqual(editableStocks.count, 0)
        let families = ["systemSmall", "systemMedium", "systemLarge"]
        for family in families {
            let preview = gallery.groups.matching(NSPredicate(format: "identifier ENDSWITH %@",
                ScreenshotFixture.widgetKind + ":" + family)).firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 15))
            preview.buttons.firstMatch.click()
        }
        record(gallery, name: "widget-added")
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        done.click()
        XCTAssertTrue(search.waitForNonExistence(timeout: 15))
        XCTAssertFalse(gallery.groups.matching(NSPredicate(format: "identifier ENDSWITH %@",
            ScreenshotFixture.widgetKind + ":systemSmall")).firstMatch.exists)
        XCTAssertFalse(done.exists)
        let placed = NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
            "widget-local:", ScreenshotFixture.widgetKind)
        record(gallery, name: "desktop-after-placement")
        let groups = gallery.groups.matching(placed)
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", families.count), object: groups)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 60), .completed)
        let owners = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == galleryMatch.identifier }
        XCTAssertEqual(owners.count, 1)
        let ownerPID = try XCTUnwrap(owners.first).processIdentifier
        let nativeWindows: [(number: Int, frame: CGRect)] = visibleWindows().compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == ownerPID,
                  let number = window[kCGWindowNumber as String] as? Int, !baseline.contains(number),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (number, frame)
        }
        let labels = ScreenshotFixture.smallWidgetAccountLabels
        XCTAssertFalse(labels.isEmpty)
        let widgets = try groups.allElementsBoundByIndex.map { group -> (number: Int, frame: CGRect) in
            for label in labels {
                let content = group.descendants(matching: .any).matching(NSPredicate(
                    format: "label == %@ OR label BEGINSWITH %@", label, label + ". ")).firstMatch
                XCTAssertTrue(content.waitForExistence(timeout: 30))
                XCTAssertTrue(group.frame.contains(content.frame))
            }
            let matches = nativeWindows.filter { $0.frame.contains(group.frame) }
            XCTAssertEqual(matches.count, 1, "Each placed fixture group must belong to one new native window")
            return try XCTUnwrap(matches.first)
        }
        XCTAssertEqual(Set(widgets.map(\.number)).count, families.count)
        XCTAssertTrue(desktop.frame.contains(center))
        XCTAssertTrue(widgets.allSatisfy { !$0.frame.contains(center) })
        nativeCoordinate(center, relativeTo: reference).hover()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let screenshot = XCUIScreen.main.screenshot()
        let display = CGMainDisplayID()
        let points = CGDisplayBounds(display).size
        let geometry: [String: Any] = [
            "screenPoints": [points.width, points.height],
            "screenPixels": [CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display)],
            "backingScaleFactor": NSScreen.main?.backingScaleFactor ?? 0,
            "widgetsPoints": widgets.map { [$0.frame.minX, $0.frame.minY, $0.frame.maxX, $0.frame.maxY] },
            "frontmostApplication": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
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

    private func nativeCoordinate(_ point: CGPoint, relativeTo reference: XCUIElement) -> XCUICoordinate {
        reference.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: point.x - reference.frame.minX, dy: point.y - reference.frame.minY))
    }

    private func visibleWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func clickVisibleWidgetMenu(_ desktop: XCUIElement, reference: XCUIElement) throws {
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
        let transform = XCTAttachment(string: "pixels=\(image.width)x\(image.height) displayPoints=\(bounds) reference=\(reference.frame) OCRBox=\(box) click=\(point)")
        transform.name = "native-menu-pixel-to-point-transform"
        transform.lifetime = .keepAlways
        add(transform)
        nativeCoordinate(point, relativeTo: reference).click()
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

    private func findOwner(stage: String, baseline: Set<Int>,
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
                if element.exists && !element.frame.isEmpty && element.isHittable {
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
            let evidence = XCTAttachment(string: alert.debugDescription)
            evidence.name = "unexpected-system-dialog"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            XCTFail("Capture stopped at an unexpected UI interruption: \(alert.label)")
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
        app.launchEnvironment = environment.filter { ["GITHUB_ACTIONS", "RUNNER_ENVIRONMENT"].contains($0.key) }
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
