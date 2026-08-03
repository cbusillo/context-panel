import ContextPanelCore
import ContextPanelValidationFixtures
import ContextPanelWidgetUI
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct ValidationGalleryView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let presentationDate: Date
    private let adapter = ValidationGalleryFixtureAdapter()

    @State private var fixtureID: ValidationFixtureID
    @State private var family: ValidationGalleryFamily
    @State private var appearance: ValidationGalleryAppearance

    public init(
        route: ValidationGalleryRoute = ValidationGalleryRoute(),
        presentationDate: Date = ValidationFixtureCatalog.referencePresentationDate
    ) {
        self.presentationDate = presentationDate
        _fixtureID = State(initialValue: route.fixtureID)
        _family = State(initialValue: route.family)
        _appearance = State(initialValue: route.appearance)
    }

    private var fixture: ValidationFixture {
        ValidationFixtureCatalog.fixture(id: fixtureID)
    }

    private var snapshot: WidgetSnapshot {
        adapter.snapshot(fixture: fixture, presentationDate: presentationDate)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ValidationSampleDataBoundary()
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
                    fixtureButton(fixture, compact: false)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(pageBackground)
    }

    private func fixtureButton(_ fixture: ValidationFixture, compact: Bool) -> some View {
        Button {
            fixtureID = fixture.id
        } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: compact ? 0 : 3) {
                    Text(fixture.title)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !compact {
                        Text(fixture.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if fixture.id == fixtureID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 11 : 12)
            .padding(.vertical, compact ? 7 : 10)
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
                ValidationGalleryWidgetTile(
                    fixture: fixture,
                    snapshot: snapshot,
                    family: family,
                    appearance: appearance,
                    presentationDate: presentationDate,
                    displayPreferences: adapter.displayPreferences
                )
                proofBoundary
            }
            .frame(maxWidth: 760, alignment: .leading)
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
            }
        }
        .frame(maxWidth: 520)
    }

    private var proofBoundary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.badge.eye")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Shared-view proof only")
                    .font(.headline)
                Text("This gallery reuses the production widget presentation with synthetic values. It does not prove WidgetKit margins, backgrounds, placement, or the signed extension execution path.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            }
            .scrollIndicators(.hidden)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }
}
