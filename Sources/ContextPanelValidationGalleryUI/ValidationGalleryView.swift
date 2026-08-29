import ContextPanelCore
import ContextPanelValidationFixtures
import ContextPanelWidgetUI
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ValidationGalleryContext: Identifiable, Sendable {
    public let fixture: ValidationFixture
    public let snapshot: WidgetSnapshot
    public let presentationDate: Date
    public let presentation: ValidationGalleryPresentation
    public let family: ValidationGalleryFamily
    public let appearance: ValidationGalleryAppearance
    public let displayPreferences: WidgetDisplayPreferences

    public init(
        fixture: ValidationFixture,
        snapshot: WidgetSnapshot,
        presentationDate: Date,
        presentation: ValidationGalleryPresentation,
        family: ValidationGalleryFamily,
        appearance: ValidationGalleryAppearance,
        displayPreferences: WidgetDisplayPreferences
    ) {
        self.fixture = fixture
        self.snapshot = snapshot
        self.presentationDate = presentationDate
        self.presentation = presentation
        self.family = family
        self.appearance = appearance
        self.displayPreferences = displayPreferences
    }

    public var id: String {
        [
            fixture.id.rawValue,
            presentation.rawValue,
            family.rawValue,
            appearance.rawValue,
        ].joined(separator: ":")
    }

    public var storedSnapshot: StoredUsageSnapshot {
        StoredUsageSnapshot(
            savedAt: snapshot.generatedAt,
            snapshot: snapshot.usageSnapshot,
            reports: snapshot.reports,
            promptCacheObservations: snapshot.promptCacheObservations
        )
    }
}

public struct ValidationGalleryView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let presentationDate: Date
    private let adapter = ValidationGalleryFixtureAdapter()
    private let supportedPresentations: [ValidationGalleryPresentation]
    private let applicationPreview: ((ValidationGalleryContext) -> AnyView)?
    private let unsupportedRequestedPresentation: ValidationGalleryPresentation?

    @State private var fixtureID: ValidationFixtureID
    @State private var family: ValidationGalleryFamily
    @State private var appearance: ValidationGalleryAppearance
    @State private var presentation: ValidationGalleryPresentation

    public init(
        route: ValidationGalleryRoute = ValidationGalleryRoute(),
        presentationDate: Date = ValidationFixtureCatalog.referencePresentationDate,
        supportedPresentations: [ValidationGalleryPresentation] = [.widget],
        applicationPreview: ((ValidationGalleryContext) -> AnyView)? = nil
    ) {
        self.presentationDate = presentationDate
        let allowedPresentations = supportedPresentations.filter { presentation in
            presentation == .widget || applicationPreview != nil
        }
        let normalizedPresentations = allowedPresentations.isEmpty ? [.widget] : allowedPresentations
        self.supportedPresentations = normalizedPresentations
        self.applicationPreview = applicationPreview
        self.unsupportedRequestedPresentation = normalizedPresentations.contains(route.presentation)
            ? nil
            : route.presentation
        _fixtureID = State(initialValue: route.fixtureID)
        _family = State(initialValue: route.family)
        _appearance = State(initialValue: route.appearance)
        _presentation = State(
            initialValue: normalizedPresentations.contains(route.presentation)
                ? route.presentation
                : normalizedPresentations[0]
        )
    }

    private var fixture: ValidationFixture {
        ValidationFixtureCatalog.fixture(id: fixtureID)
    }

    private var snapshot: WidgetSnapshot {
        adapter.snapshot(fixture: fixture, presentationDate: presentationDate)
    }

    private var context: ValidationGalleryContext {
        ValidationGalleryContext(
            fixture: fixture,
            snapshot: snapshot,
            presentationDate: presentationDate,
            presentation: presentation,
            family: family,
            appearance: appearance,
            displayPreferences: adapter.displayPreferences
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            ValidationSampleDataBoundary()
            if let unsupportedRequestedPresentation {
                ValidationUnsupportedPresentationBoundary(
                    requested: unsupportedRequestedPresentation,
                    selected: presentation
                )
            }
            Divider()
            GeometryReader { geometry in
                if geometry.size.width >= 700 {
                    HStack(spacing: 0) {
                        fixtureSidebar
                            .frame(width: 260)
                        Divider()
                        galleryDetail
                    }
                } else {
                    VStack(spacing: 0) {
                        compactFixturePicker
                        Divider()
                        galleryDetail
                    }
                }
            }
        }
        .navigationTitle("Validation Gallery")
        .background(pageBackground)
        .validationGalleryActivity()
    }

    private var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        colorScheme == .dark ? Color.black : Color.white
        #endif
    }

    private var fixtureSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(ValidationFixtureCatalog.all) { fixture in
                    fixtureButton(fixture)
                }
            }
            .padding(12)
        }
        .background(pageBackground)
    }

    private var compactFixturePicker: some View {
        HStack(spacing: 12) {
            Text("Sample state")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker("Sample state", selection: $fixtureID) {
                ForEach(ValidationFixtureCatalog.all) { fixture in
                    Text(fixture.title).tag(fixture.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("gallery-fixture-picker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pageBackground)
    }

    private func fixtureButton(_ fixture: ValidationFixture) -> some View {
        Button {
            fixtureID = fixture.id
        } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(fixture.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(fixture.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if fixture.id == fixtureID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                fixture.id == fixtureID ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sample data: \(fixture.title)")
        .accessibilityAddTraits(fixture.id == fixtureID ? .isSelected : [])
    }

    private var galleryDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                detailHeader
                controls
                galleryPreview
                proofBoundary
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(pageBackground)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fixture.title)
                .font(.title2.weight(.semibold))
            Text(fixture.purpose)
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Fixed presentation time: \(presentationDate.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if supportedPresentations.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Presentation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Presentation", selection: $presentation) {
                        ForEach(supportedPresentations) { presentation in
                            Text(presentation.displayName).tag(presentation)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("gallery-presentation-picker")
                }
            }

            if presentation == .widget {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Widget size")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Widget size", selection: $family) {
                        ForEach(ValidationGalleryFamily.allCases) { family in
                            Text(family.displayName).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("gallery-family-picker")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Appearance", selection: $appearance) {
                    ForEach(ValidationGalleryAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityIdentifier("gallery-appearance-picker")
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var galleryPreview: some View {
        if presentation == .widget {
            ValidationGalleryWidgetTile(
                fixture: fixture,
                snapshot: snapshot,
                family: family,
                appearance: appearance,
                presentationDate: presentationDate,
                displayPreferences: adapter.displayPreferences
            )
        } else if let applicationPreview {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(presentation.displayName) presentation")
                        .font(.headline)
                    Spacer()
                    Text("SAMPLE DATA")
                        .font(.caption2.weight(.bold))
                        .tracking(0.7)
                        .foregroundStyle(.orange)
                }
                applicationPreview(context)
                    .id(context.id)
                    .allowsHitTesting(false)
            }
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
        }
    }

    private var proofBoundary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.badge.eye")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Shared-view proof only")
                    .font(.headline)
                Text(proofBoundaryCopy)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var proofBoundaryCopy: String {
        if presentation == .widget {
            return "This gallery reuses the production widget presentation with synthetic values. It does not prove WidgetKit margins, backgrounds, placement, or the signed extension execution path."
        }
        return "This gallery reuses the production app presentation with synthetic values. It proves shared layout and copy only, not signed runtime identity, CloudKit or App Group access, platform compositing, or hardware lifecycle behavior."
    }
}

private struct ValidationUnsupportedPresentationBoundary: View {
    let requested: ValidationGalleryPresentation
    let selected: ValidationGalleryPresentation

    var body: some View {
        Label(
            "Unsupported requested presentation \(requested.rawValue); showing \(selected.rawValue).",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
        .accessibilityIdentifier("gallery-unsupported-presentation")
    }
}

public struct ValidationSampleDataBoundary: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "testtube.2")
                .font(.headline)
            VStack(alignment: .leading, spacing: 1) {
                Text("SAMPLE DATA")
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
                Text("Read-only validation fixtures · never live account data")
                    .font(.caption)
            }
            Spacer(minLength: 12)
            Text("Shared-view proof")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.orange.opacity(0.18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sample data. Read-only validation fixtures. Shared-view proof only.")
    }
}

private struct ValidationGalleryWidgetTile: View {
    @Environment(\.colorScheme) private var hostColorScheme

    let fixture: ValidationFixture
    let snapshot: WidgetSnapshot
    let family: ValidationGalleryFamily
    let appearance: ValidationGalleryAppearance
    let presentationDate: Date
    let displayPreferences: WidgetDisplayPreferences

    private var themeVariant: CPWThemeVariant {
        switch appearance {
        case .adaptive:
            .adaptive
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var previewColorScheme: ColorScheme {
        switch appearance {
        case .adaptive:
            hostColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var links: ContextPanelWidgetLinks {
        let inertURL = URL(string: "contextpanel-validation://sample")!
        return ContextPanelWidgetLinks(
            overview: inertURL,
            reconnect: inertURL,
            cacheStatsSettings: inertURL,
            resetCreditInteraction: .none
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(family.displayName) widget")
                    .font(.headline)
                Spacer()
                Text("SAMPLE DATA")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.orange)
            }

            ScrollView(.horizontal) {
                ContextPanelWidgetContentView(
                    family: family.widgetFamily,
                    snapshot: snapshot,
                    displayPreferences: displayPreferences,
                    links: links,
                    showsResetCreditSurfaces: true,
                    presentationDate: presentationDate
                )
                .cpwThemeVariant(themeVariant)
                .environment(\.colorScheme, previewColorScheme)
                .frame(width: family.width, height: family.height)
                .background(
                    CPWTheme.surface(variant: themeVariant),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
                .padding(2)
                .allowsHitTesting(false)
            }
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }
}
