import XCTest

final class ContextPanelCompanionSharedViewCaptureUITests: XCTestCase {
    private static let maximumSampleCount = 6
    private static let sampleDelay: UInt32 = 3

    func testCaptureSharedView() throws {
        let request = try CaptureRequest(environment: ProcessInfo.processInfo.environment)
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
        let baselineWindow = try largestAppWindow(in: app)

        captureStableScreenshots(named: "baseline") {
            baselineWindow.screenshot()
        }

        app.open(request.url)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
        try verifyRoute(request, in: app)
        let galleryWindow = try largestAppWindow(in: app)

        captureStableScreenshots(named: "routed") {
            galleryWindow.screenshot()
        }
    }

    private func verifyRoute(_ request: CaptureRequest, in app: XCUIApplication) throws {
        let fixturePicker = app.descendants(matching: .any)
            .matching(identifier: "gallery-fixture-picker")
            .firstMatch
        XCTAssertTrue(fixturePicker.waitForExistence(timeout: 60))
        XCTAssertEqual(fixturePicker.label, "Sample state, \(request.fixtureTitle)")
        XCTAssertTrue(app.staticTexts[request.fixtureTitle].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Shared-view proof only"].waitForExistence(timeout: 30))

        try verifySelectedSegment(
            identifier: "gallery-presentation-picker",
            title: request.presentationTitle,
            in: app
        )
        try verifySelectedSegment(
            identifier: "gallery-appearance-picker",
            title: request.appearanceTitle,
            in: app
        )
        if request.presentation == "widget" {
            try verifySelectedSegment(
                identifier: "gallery-family-picker",
                title: request.familyTitle,
                in: app
            )
        }
    }

    private func verifySelectedSegment(
        identifier: String,
        title: String,
        in app: XCUIApplication
    ) throws {
        let control = app.descendants(matching: .segmentedControl)
            .matching(identifier: identifier)
            .firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        let segment = control.buttons[title]
        XCTAssertTrue(segment.exists)
        XCTAssertTrue(segment.isSelected)
    }

    private func largestAppWindow(in app: XCUIApplication) throws -> XCUIElement {
        let candidates = app.windows.allElementsBoundByIndex.filter { window in
            window.frame.width > 0 && window.frame.height > 0
        }
        let sorted = candidates.sorted { lhs, rhs in
            lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
        }
        guard let selected = sorted.first else {
            throw CaptureError.galleryWindowUnavailable
        }
        if sorted.count > 1 {
            let selectedArea = selected.frame.width * selected.frame.height
            let nextArea = sorted[1].frame.width * sorted[1].frame.height
            guard selectedArea > nextArea else {
                throw CaptureError.galleryWindowAmbiguous
            }
        }
        return selected
    }

    private func captureStableScreenshots(
        named prefix: String,
        capture: () -> XCUIScreenshot
    ) {
        var previousData: Data?
        for sample in 1 ... Self.maximumSampleCount {
            let screenshot = capture()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "\(prefix)-\(sample)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if screenshot.pngRepresentation == previousData {
                return
            }
            previousData = screenshot.pngRepresentation
            if sample < Self.maximumSampleCount {
                sleep(Self.sampleDelay)
            }
        }
    }
}

private struct CaptureRequest {
    private static let urlEnvironmentKey = "CONTEXT_PANEL_SHARED_VIEW_URL"
    private static let expectedQueryNames = Set([
        "fixture",
        "family",
        "appearance",
        "presentation",
    ])

    let url: URL
    let fixtureTitle: String
    let familyTitle: String
    let appearanceTitle: String
    let presentation: String
    let presentationTitle: String

    init(environment: [String: String]) throws {
        let urlString = try Self.value(Self.urlEnvironmentKey, in: environment)
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "contextpanelcompanion",
              components.host == "validation-gallery",
              components.path.isEmpty,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil
        else {
            throw CaptureError.invalidRoute
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard Self.expectedQueryNames.contains(item.name),
                  query[item.name] == nil,
                  let value = item.value,
                  !value.isEmpty
            else {
                throw CaptureError.invalidRoute
            }
            query[item.name] = value
        }
        guard Set(query.keys) == Self.expectedQueryNames else {
            throw CaptureError.invalidRoute
        }

        let fixture = try Self.value("CONTEXT_PANEL_SHARED_VIEW_FIXTURE", in: environment)
        let family = try Self.value("CONTEXT_PANEL_SHARED_VIEW_FAMILY", in: environment)
        let appearance = try Self.value("CONTEXT_PANEL_SHARED_VIEW_APPEARANCE", in: environment)
        let presentation = try Self.value("CONTEXT_PANEL_SHARED_VIEW_PRESENTATION", in: environment)
        guard query["fixture"] == fixture,
              query["family"] == family,
              query["appearance"] == appearance,
              query["presentation"] == presentation
        else {
            throw CaptureError.routeMismatch
        }

        self.url = url
        fixtureTitle = try Self.value(
            "CONTEXT_PANEL_SHARED_VIEW_FIXTURE_TITLE",
            in: environment
        )
        familyTitle = try Self.value(
            "CONTEXT_PANEL_SHARED_VIEW_FAMILY_TITLE",
            in: environment
        )
        appearanceTitle = try Self.value(
            "CONTEXT_PANEL_SHARED_VIEW_APPEARANCE_TITLE",
            in: environment
        )
        self.presentation = presentation
        presentationTitle = try Self.value(
            "CONTEXT_PANEL_SHARED_VIEW_PRESENTATION_TITLE",
            in: environment
        )
    }

    private static func value(
        _ key: String,
        in environment: [String: String]
    ) throws -> String {
        guard let value = environment[key],
              !value.isEmpty,
              value.utf8.count <= 256,
              !value.contains("\n"),
              !value.contains("\r")
        else {
            throw CaptureError.invalidEnvironment
        }
        return value
    }
}

private enum CaptureError: Error {
    case galleryWindowAmbiguous
    case galleryWindowUnavailable
    case invalidEnvironment
    case invalidRoute
    case routeMismatch
}
