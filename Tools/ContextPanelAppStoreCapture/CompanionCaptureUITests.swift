import ContextPanelCore
import XCTest
#if os(visionOS)
import Vision
#endif

@MainActor
final class CompanionCaptureUITests: XCTestCase {
    func testNativeFixtureScreen() throws {
        ScreenshotFixture.configureProcess()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Capture has no permission-grant authority") { alert in
            let evidence = XCTAttachment(string: alert.debugDescription)
            evidence.name = "unexpected-system-dialog"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            XCTFail("Capture stopped at an unexpected system dialog: \(alert.label)")
            return true
        }
        let app = XCUIApplication()
        if !(ProcessInfo.processInfo.environment["CP_CAPTURE_WIDGET"] ?? "").isEmpty {
            XCTAssertFalse(ScreenshotFixture.smallWidgetAccountLabels.isEmpty)
        }
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
            #if os(visionOS)
            try placeSpatialFixtureWidget()
            #else
            try placeFixtureWidget(reusing: widgetMode == "present")
            #endif
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "native-fixture"
        image.lifetime = .keepAlways
        add(image)
    }

    #if os(visionOS)
    private func placeSpatialFixtureWidget() throws {
        let gallery = XCUIApplication(bundleIdentifier: "com.apple.RealityWidgets")
        gallery.launch()
        let foreground = gallery.wait(for: .runningForeground, timeout: 60)
        recordHierarchy(gallery, name: "spatial-widget-gallery")
        XCTAssertTrue(foreground)
        let search = gallery.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 30))
        search.tap()
        search.typeText("Context Panel")
        let result = gallery.collectionViews["LibraryAppsListView"].cells
            .containing(.staticText, identifier: "Context Panel").firstMatch
        let found = result.waitForExistence(timeout: 30)
        recordHierarchy(gallery, name: "spatial-widget-search")
        XCTAssertTrue(found)
        result.tap()
        let add = addWidgetButton(gallery)
        let preview = add.waitForExistence(timeout: 30)
        recordHierarchy(gallery, name: "spatial-widget-preview")
        XCTAssertTrue(preview)
        add.tap()
        let done = gallery.buttons["Done"].firstMatch
        let placed = done.waitForExistence(timeout: 30)
        recordHierarchy(gallery, name: "spatial-widget-placement")
        XCTAssertTrue(placed)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
        recordHierarchy(gallery, name: "spatial-after-done")
        let chrome = XCUIApplication(bundleIdentifier: "com.apple.RealityChrome")
        recordHierarchy(chrome, name: "spatial-window-chrome")
        let widget = gallery.windows.matching(NSPredicate(format: "identifier ENDSWITH %@",
            " - " + ScreenshotFixture.widgetKind)).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 30))
        try waitForSpatialWidgetPixels(widget)
        recordHierarchy(gallery, name: "spatial-widget-placed")
    }

    private func waitForSpatialWidgetPixels(_ widget: XCUIElement) throws {
        let names = ScreenshotFixture.smallWidgetAccountNames
        XCTAssertFalse(names.isEmpty)
        let deadline = Date().addingTimeInterval(30)
        var evidence: XCUIScreenshot?
        var recognized = ""
        var ready = false
        repeat {
            let screenshot = widget.screenshot()
            evidence = screenshot
            let image = try XCTUnwrap(screenshot.image.cgImage)
            XCTAssertEqual(Double(image.width) / Double(image.height),
                           Double(widget.frame.width / widget.frame.height), accuracy: 0.01)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let compact = recognized.replacingOccurrences(of: " ", with: "").lowercased()
            ready = names.allSatisfy { compact.contains($0.replacingOccurrences(of: " ", with: "").lowercased()) }
            if ready { break }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while Date() < deadline
        let text = XCTAttachment(string: recognized)
        text.name = "placed-widget-recognized-text"
        text.lifetime = .keepAlways
        add(text)
        if let evidence {
            let image = XCTAttachment(screenshot: evidence)
            image.name = "placed-widget-plane"
            image.lifetime = .keepAlways
            add(image)
        }
        XCTAssertTrue(ready, "The placed widget must render its fixture account names")
    }
    #endif

    #if !os(visionOS)
    private func placeFixtureWidget(reusing: Bool) throws {
        let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        if reusing { try showFirstHomePage(home) }
        else { try addFixtureWidget(home) }
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

    private func addFixtureWidget(_ home: XCUIApplication) throws {
        let background = home.otherElements["Home screen icons"].firstMatch
        let foundBackground = background.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "home")
        XCTAssertTrue(foundBackground)
        background.press(forDuration: 2)
        let edit = home.buttons["Edit"].firstMatch
        let foundToolbar = edit.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "home-edit")
        XCTAssertTrue(foundToolbar)
        try showFirstHomePage(home)
        try removeStockWidgetsIfPresent(home)
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

    private func removeStockWidgetsIfPresent(_ home: XCUIApplication) throws {
        let icons = home.otherElements["Home screen icons"].icons
        func stock(_ name: String) -> XCUIElement {
            icons.matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", name, "Widget")).firstMatch
        }
        guard stock("News").exists else { return }
        for name in ["News", "Reminders", "Calendar"] {
            let widget = stock(name)
            XCTAssertTrue(widget.exists)
            XCTAssertTrue(home.frame.contains(widget.frame))
            widget.buttons["DeleteButton"].tap()
            let confirmation = home.alerts.firstMatch
            let found = confirmation.waitForExistence(timeout: 10)
            recordHierarchy(home, name: "remove-stock-" + name)
            XCTAssertTrue(found)
            let remove = confirmation.buttons["Remove"].firstMatch
            XCTAssertTrue(remove.exists)
            remove.tap()
            XCTAssertTrue(widget.waitForNonExistence(timeout: 10))
        }
    }

    private func showFirstHomePage(_ home: XCUIApplication) throws {
        let indicator = home.pageIndicators["Page control"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        let value = try XCTUnwrap(indicator.value as? String)
        let words = value.split(separator: " ")
        let page = try XCTUnwrap(words.count > 1 ? Int(words[1]) : nil)
        XCTAssertGreaterThan(page, 0)
        for _ in 1 ..< page { home.swipeRight() }
        XCTAssertTrue((indicator.value as? String)?.hasPrefix("Page 1 of ") == true)
    }

    #endif

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
