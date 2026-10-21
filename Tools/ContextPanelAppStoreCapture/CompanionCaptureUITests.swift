import ContextPanelCore
import XCTest

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
        _ = content.waitForExistence(timeout: 90)
        recordHierarchy(app, name: capturesDetail ? "detail" : "overview")
        XCTAssertTrue(content.exists)
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
        _ = result.waitForExistence(timeout: 30)
        recordHierarchy(gallery, name: "spatial-widget-search")
        XCTAssertTrue(result.exists)
        result.tap()
        let add = addWidgetButton(gallery)
        _ = add.waitForExistence(timeout: 30)
        recordHierarchy(gallery, name: "spatial-widget-preview")
        XCTAssertTrue(add.exists)
        add.tap()
        let done = gallery.buttons["Done"].firstMatch
        _ = done.waitForExistence(timeout: 30)
        recordHierarchy(gallery, name: "spatial-widget-placement")
        XCTAssertTrue(done.exists)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 15))
        recordHierarchy(gallery, name: "spatial-after-done")
        let chrome = XCUIApplication(bundleIdentifier: "com.apple.RealityChrome")
        recordHierarchy(chrome, name: "spatial-window-chrome")
        let library = gallery.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@",
            "com.apple.RealityWidgets:SFBSystemService-"))
            .containing(.collectionView, identifier: "LibraryAppsListView")
        XCTAssertEqual(library.count, 1)
        let libraryID = library.element.identifier
        let libraryChrome = chrome.otherElements.matching(NSPredicate(format: "identifier ENDSWITH %@", libraryID))
            .containing(.button, identifier: "CloseButton")
        XCTAssertEqual(libraryChrome.count, 1)
        XCTContext.runActivity(named: "spatial-library-close") { _ in
            libraryChrome.element.buttons["CloseButton"].tap()
        }
        XCTAssertTrue(gallery.collectionViews["LibraryAppsListView"].waitForNonExistence(timeout: 15))
        let widget = gallery.windows.matching(NSPredicate(format: "identifier ENDSWITH %@",
            " - " + ScreenshotFixture.widgetKind)).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 30))
        // The retained renderer trace transitions the placed scene to Live about
        // five seconds after Library closure. Review the full OS frame below;
        // scene-local element frames cannot crop the projected room correctly.
        RunLoop.current.run(until: Date().addingTimeInterval(15))
        XCTAssertTrue(widget.exists)
        recordHierarchy(gallery, name: "spatial-widget-placed")
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
        _ = background.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "home")
        XCTAssertTrue(background.exists)
        background.press(forDuration: 2)
        let edit = home.buttons["Edit"].firstMatch
        _ = edit.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "home-edit")
        XCTAssertTrue(edit.exists)
        try showFirstHomePage(home)
        try removeStockWidgetsIfPresent(home)
        edit.tap()
        let addWidget = addWidgetButton(home)
        _ = addWidget.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "edit-menu")
        XCTAssertTrue(addWidget.exists)
        addWidget.tap()
        let search = home.searchFields.firstMatch
        _ = search.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-gallery")
        XCTAssertTrue(search.exists)
        search.tap()
        search.typeText("Context Panel")
        let result = home.cells["Context Panel"].firstMatch
        _ = result.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-search")
        XCTAssertTrue(result.exists)
        result.tap()
        let add = addWidgetButton(home)
        _ = add.waitForExistence(timeout: 30)
        recordHierarchy(home, name: "widget-preview")
        XCTAssertTrue(add.exists)
        add.tap()
        XCTAssertTrue(add.waitForNonExistence(timeout: 15))
        let done = home.buttons["Done"].firstMatch
        _ = done.waitForExistence(timeout: 10)
        recordHierarchy(home, name: "widget-added")
        XCTAssertTrue(done.exists)
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
            _ = confirmation.waitForExistence(timeout: 10)
            recordHierarchy(home, name: "remove-stock-" + name)
            XCTAssertTrue(confirmation.exists)
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
