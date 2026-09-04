import ContextPanelCompanionSupport
import ContextPanelCore
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import ContextPanelWidgetUI
import SwiftUI
import UIKit
import WidgetKit
import XCTest

@MainActor
final class ContextPanelCompanionSharedViewCaptureUITests: XCTestCase {
    private static let maximumSampleCount = 6
    private static let sampleDelay: UInt32 = 3

    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureSharedView() throws {
        let request = try CaptureRequest(environment: ProcessInfo.processInfo.environment)
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 90))
        verifyRequest(request)

        try captureStableImages(named: "baseline") {
            try renderedGalleryPNG(route: .captureBaseline)
        }

        try captureStableImages(named: "routed") {
            try renderedGalleryPNG(route: request.route)
        }
    }

    private func verifyRequest(_ request: CaptureRequest) {
        XCTAssertEqual(
            request.fixtureTitle,
            ValidationFixtureCatalog.fixture(id: request.route.fixtureID).title
        )
        XCTAssertEqual(request.familyTitle, request.route.family.displayName)
        XCTAssertEqual(request.appearanceTitle, request.route.appearance.displayName)
        XCTAssertEqual(request.presentationTitle, request.route.presentation.displayName)
    }

    private func renderedGalleryPNG(route: ValidationGalleryRoute) throws -> Data {
        let content = CaptureGalleryView(route: route)
            .frame(width: 840, height: 900)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else {
            throw CaptureError.imageRenderingFailed
        }
        return data
    }

    private func captureStableImages(
        named prefix: String,
        capture: () throws -> Data
    ) throws {
        var previousData: Data?
        for sample in 1 ... Self.maximumSampleCount {
            let data = try capture()
            let attachment = XCTAttachment(
                data: data,
                uniformTypeIdentifier: "public.png"
            )
            attachment.name = "\(prefix)-\(sample)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if data == previousData {
                return
            }
            previousData = data
            if sample < Self.maximumSampleCount {
                sleep(Self.sampleDelay)
            }
        }
    }
}

private struct CaptureGalleryView: View {
    @Environment(\.colorScheme) private var hostColorScheme

    let route: ValidationGalleryRoute

    private let adapter = ValidationGalleryFixtureAdapter()

    private var fixture: ValidationFixture {
        ValidationFixtureCatalog.fixture(id: route.fixtureID)
    }

    private var presentationDate: Date {
        ValidationFixtureCatalog.referencePresentationDate
    }

    private var snapshot: WidgetSnapshot {
        adapter.snapshot(fixture: fixture, presentationDate: presentationDate)
    }

    private var previewColorScheme: ColorScheme {
        switch route.appearance {
        case .adaptive:
            hostColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var themeVariant: CPWThemeVariant {
        previewColorScheme == .dark ? .dark : .light
    }

    private var pageBackground: Color {
        previewColorScheme == .dark
            ? Color(red: 0.07, green: 0.075, blue: 0.085)
            : Color(red: 0.94, green: 0.945, blue: 0.96)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "testtube.2")
                    .font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("SAMPLE DATA")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                    Text("Read-only validation fixtures · never live account data")
                        .font(.subheadline)
                }
                Spacer()
                Text("Shared-view proof")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.09), in: Capsule())
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .frame(height: 78)
            .background(Color(red: 1, green: 0.53, blue: 0.12))

            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Sample state")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    selectionChip(fixture.title)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(fixture.title)
                        .font(.title2.weight(.semibold))
                    Text(fixture.purpose)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text(
                        "Fixed presentation time · "
                            + presentationDate.formatted(date: .abbreviated, time: .shortened)
                    )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 14) {
                    selectionCard(label: "Presentation", value: route.presentation.displayName)
                    selectionCard(label: "Appearance", value: route.appearance.displayName)
                    if route.presentation == .widget {
                        selectionCard(label: "Family", value: route.family.displayName)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(route.presentation.displayName) presentation")
                            .font(.headline)
                        Spacer()
                        Text("SAMPLE DATA")
                            .font(.caption.weight(.bold))
                            .tracking(1)
                            .foregroundStyle(.orange)
                    }
                    preview
                }
                .padding(18)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(previewColorScheme == .dark ? Color.white : Color.black)
        .background(pageBackground)
        .environment(\.colorScheme, previewColorScheme)
    }

    @ViewBuilder
    private var preview: some View {
        if route.presentation == .widget {
            ContextPanelWidgetContentView(
                family: route.family.widgetFamily,
                snapshot: snapshot,
                displayPreferences: adapter.displayPreferences,
                links: CompanionDeepLinks.previewLinks,
                showsResetCreditSurfaces: true,
                resetCreditMaximumAge: SnapshotFreshness.companionProviderMaximumAge,
                presentationDate: presentationDate
            )
            .cpwThemeVariant(themeVariant)
            .frame(width: route.family.width, height: route.family.height)
            .background(
                CPWTheme.surface(variant: themeVariant),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            ContextPanelWidgetContentView(
                family: .systemLarge,
                snapshot: snapshot,
                displayPreferences: adapter.displayPreferences,
                links: CompanionDeepLinks.previewLinks,
                showsResetCreditSurfaces: true,
                resetCreditMaximumAge: SnapshotFreshness.companionProviderMaximumAge,
                presentationDate: presentationDate
            )
            .cpwThemeVariant(themeVariant)
            .frame(maxWidth: .infinity, minHeight: 420)
            .background(
                CPWTheme.surface(variant: themeVariant),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    private func selectionChip(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.09), in: Capsule())
    }

    private func selectionCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension ValidationGalleryRoute {
    static let captureBaseline = ValidationGalleryRoute(
        fixtureID: .missing,
        family: .systemSmall,
        appearance: .adaptive,
        presentation: .widget
    )
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
    let route: ValidationGalleryRoute
    let fixtureTitle: String
    let familyTitle: String
    let appearanceTitle: String
    let presentation: String
    let presentationTitle: String

    init(environment: [String: String]) throws {
        let urlString = try Self.value(Self.urlEnvironmentKey, in: environment)
        guard let url = URL(string: urlString),
              let route = ValidationGalleryRoute(url: url),
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
        self.route = route
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
    case imageRenderingFailed
    case invalidEnvironment
    case invalidRoute
    case routeMismatch
}
