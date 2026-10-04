import ContextPanelCore
import SwiftUI
import WidgetKit

public enum SettingsWidgetPreviewFamily: String, CaseIterable, Identifiable {
    case small, medium, large
    public var id: Self { self }
    public var title: String { rawValue.capitalized }
    public var widgetFamily: WidgetFamily {
        switch self {
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        }
    }
    public var size: CGSize {
        switch self {
        case .small: CGSize(width: 164, height: 164)
        case .medium: CGSize(width: 344, height: 164)
        case .large: CGSize(width: 344, height: 344)
        }
    }
}

/// A static glance using the widget itself. Preview links remain inert even for
/// accessibility activation, without disabling or dimming the widget's content.
public struct SettingsWidgetPreview: View {
    let snapshot: WidgetSnapshot
    let preferences: WidgetDisplayPreferences
    let family: SettingsWidgetPreviewFamily
    let presentationDate: Date
    @Environment(\.colorScheme) private var colorScheme

    public init(snapshot: WidgetSnapshot, preferences: WidgetDisplayPreferences,
                family: SettingsWidgetPreviewFamily, presentationDate: Date) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.family = family
        self.presentationDate = presentationDate
    }

    public var body: some View {
        ContextPanelWidgetContentView(
            family: family.widgetFamily, snapshot: snapshot, displayPreferences: preferences,
            links: ContextPanelWidgetLinks(
                overview: URL(string: "contextpanel://overview")!,
                reconnect: URL(string: "contextpanel://reconnect")!,
                cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!,
                resetCreditInteraction: .none
            ),
            showsResetCreditSurfaces: true, presentationDate: presentationDate,
            allowsNavigation: false
        )
        .cpwThemeVariant(colorScheme == .dark ? .dark : .light)
        .frame(width: family.size.width, height: family.size.height)
        .background(CPWTheme.surface(variant: colorScheme == .dark ? .dark : .light))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.08)))
        .environment(\.openURL, OpenURLAction { _ in .discarded })
        .allowsHitTesting(false)
    }
}
