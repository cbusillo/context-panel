import ContextPanelCore
import SwiftUI
import WidgetKit

#if canImport(AppKit)
import AppKit
private typealias CPWPlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
private typealias CPWPlatformColor = UIColor
#endif

public enum CPWThemeVariant: Sendable {
    case adaptive
    case light
    case dark
}

private struct CPWThemeVariantKey: EnvironmentKey {
    static let defaultValue: CPWThemeVariant = .adaptive
}

private struct CPWPresentationDateKey: EnvironmentKey {
    static let defaultValue = Date()
}

private struct CPWNavigationEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var cpwNavigationEnabled: Bool {
        get { self[CPWNavigationEnabledKey.self] }
        set { self[CPWNavigationEnabledKey.self] = newValue }
    }
}

/// Preview content keeps the same spoken labels without exposing a link action.
struct CPWNavigationLink<Content: View>: View {
    let destination: URL
    @ViewBuilder var content: () -> Content
    @Environment(\.cpwNavigationEnabled) private var enabled

    var body: some View {
        if enabled { Link(destination: destination, label: content) }
        else { content() }
    }
}

private struct CPWNavigationHint: ViewModifier {
    let hint: String
    @Environment(\.cpwNavigationEnabled) private var enabled

    func body(content: Content) -> some View {
        content.accessibilityHint(enabled ? hint : "")
    }
}

extension View {
    func cpwNavigationHint(_ hint: String) -> some View {
        modifier(CPWNavigationHint(hint: hint))
    }
}

public extension EnvironmentValues {
    var cpwThemeVariant: CPWThemeVariant {
        get { self[CPWThemeVariantKey.self] }
        set { self[CPWThemeVariantKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var cpwPresentationDate: Date {
        get { self[CPWPresentationDateKey.self] }
        set { self[CPWPresentationDateKey.self] = newValue }
    }
}

public extension View {
    func cpwThemeVariant(_ variant: CPWThemeVariant) -> some View {
        environment(\.cpwThemeVariant, variant)
    }
}

public struct ContextPanelWidgetLinks: Sendable {
    public let overview: URL

    public func account(_ provider: Provider, id: String) -> URL {
        var components = URLComponents()
        components.scheme = overview.scheme
        components.host = "provider"
        components.path = "/\(provider.rawValue)"
        components.queryItems = [URLQueryItem(name: "account", value: id)]
        return components.url ?? overview
    }

    public var deadlines: URL {
        var components = URLComponents()
        components.scheme = overview.scheme
        components.host = "deadlines"
        return components.url ?? overview
    }

    public init(overview: URL) {
        self.overview = overview
    }
}

public struct ContextPanelWidgetContentView: View {
    let family: WidgetFamily
    let snapshot: WidgetSnapshot
    let links: ContextPanelWidgetLinks
    let showsResetCreditSurfaces: Bool
    let resetCreditMaximumAge: TimeInterval
    let presentationDate: Date
    let allowsNavigation: Bool

    public init(
        family: WidgetFamily,
        snapshot: WidgetSnapshot,
        links: ContextPanelWidgetLinks,
        showsResetCreditSurfaces: Bool = false,
        resetCreditMaximumAge: TimeInterval = SnapshotFreshness.widgetMaximumAge,
        presentationDate: Date = Date(),
        allowsNavigation: Bool = true
    ) {
        self.family = family
        self.snapshot = snapshot
        self.links = links
        self.showsResetCreditSurfaces = showsResetCreditSurfaces
        self.resetCreditMaximumAge = resetCreditMaximumAge
        self.presentationDate = presentationDate
        self.allowsNavigation = allowsNavigation
    }

    public var body: some View {
        content
            .environment(\.cpwPresentationDate, presentationDate)
            .widgetURL(allowsNavigation ? widgetDestination : nil)
            .environment(\.cpwNavigationEnabled, allowsNavigation)
    }

    private var widgetDestination: URL? {
        let accounts = snapshot.accountOverview(now: presentationDate, widgetsOnly: true,
            maximumAge: resetCreditMaximumAge)
        if family == .systemSmall, let account = accounts.widgetTapAccount {
            return links.account(account.metadata.provider, id: account.id)
        }
        return links.overview
    }

    private var content: some View {
        AccountGlanceWidget(family: family, snapshot: snapshot, links: links,
            now: presentationDate, maximumAge: resetCreditMaximumAge,
            showsBanked: showsResetCreditSurfaces)
    }
}

public enum CPWTheme {
    // Exposed so platform widget targets can apply the shared surface behind the rendered content.
    public static let surface = surface(variant: .adaptive)

    public static func surface(variant: CPWThemeVariant) -> Color {
        themedColor(
            light: CPWPlatformColor(red: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1),
            dark: CPWPlatformColor(red: 32 / 255, green: 33 / 255, blue: 36 / 255, alpha: 1),
            variant: variant
        )
    }

    private static func themedColor(
        light: CPWPlatformColor,
        dark: CPWPlatformColor,
        variant: CPWThemeVariant
    ) -> Color {
        switch variant {
        case .adaptive:
            adaptiveColor(light: light, dark: dark)
        case .light:
            fixedColor(light)
        case .dark:
            fixedColor(dark)
        }
    }

    #if canImport(AppKit)
    private static func fixedColor(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        })
    }
    #elseif canImport(UIKit)
    private static func fixedColor(_ color: UIColor) -> Color {
        Color(uiColor: color)
    }

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    #else
    private static func fixedColor(_ color: Color) -> Color {
        color
    }

    private static func adaptiveColor(light: Color, dark: Color) -> Color {
        light
    }
    #endif
}

