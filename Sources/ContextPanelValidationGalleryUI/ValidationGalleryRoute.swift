import ContextPanelValidationFixtures
import Foundation
import WidgetKit

public enum ValidationGalleryFamily: String, CaseIterable, Identifiable, Sendable {
    case systemSmall
    case systemMedium
    case systemLarge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .systemSmall:
            "Small"
        case .systemMedium:
            "Medium"
        case .systemLarge:
            "Large"
        }
    }

    public var widgetFamily: WidgetFamily {
        switch self {
        case .systemSmall:
            .systemSmall
        case .systemMedium:
            .systemMedium
        case .systemLarge:
            .systemLarge
        }
    }

    public var width: CGFloat {
        switch self {
        case .systemSmall:
            164
        case .systemMedium, .systemLarge:
            344
        }
    }

    public var height: CGFloat {
        switch self {
        case .systemSmall, .systemMedium:
            164
        case .systemLarge:
            344
        }
    }

    /// The frame `host` gives this family when the widget is placed.
    public func frame(on host: SharedViewHost) -> SharedViewFrame {
        let size: (width: CGFloat, height: CGFloat) = switch (host, self) {
        // Apple publishes no macOS widget sizes; the Mac keeps the gallery's reference size.
        case (.mac, _): (width, height)
        // iPhone 16 (393 x 852 pt) and Apple Vision Pro share the HIG sizes.
        case (.phone, .systemSmall), (.vision, .systemSmall): (158, 158)
        case (.phone, .systemMedium), (.vision, .systemMedium): (338, 158)
        case (.phone, .systemLarge), (.vision, .systemLarge): (338, 354)
        // iPad Air 11-inch (820 x 1180 pt) canvas sizes; the system scales the canvas onto the Home Screen.
        case (.pad, .systemSmall): (155, 155)
        case (.pad, .systemMedium): (342, 155)
        case (.pad, .systemLarge): (342, 342)
        }
        return SharedViewFrame(
            width: size.width,
            height: size.height,
            cornerRadius: SharedViewFrame.widgetCornerRadius
        )
    }
}

/// The device a shared-view cell is drawn for.
public enum SharedViewHost: Sendable {
    case mac
    case phone
    case pad
    case vision

    /// The content area an app presentation fills: the window's detail area on the
    /// Mac, the screen width on iPhone and iPad, and the default window on Vision Pro.
    public var applicationFrame: SharedViewFrame {
        let size: (width: CGFloat, height: CGFloat) = switch self {
        case .mac: (860, 720)
        case .phone: (393, 420)
        case .pad: (820, 420)
        case .vision: (1_280, 420)
        }
        return SharedViewFrame(width: size.width, height: size.height, cornerRadius: 0)
    }
}

public enum ValidationGalleryAppearance: String, CaseIterable, Identifiable, Sendable {
    case adaptive
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .adaptive:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}

public enum ValidationGalleryPresentation: String, CaseIterable, Identifiable, Sendable {
    case overview
    case detail
    case reconnect
    case diagnostics
    case settings
    case widget

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .overview:
            "Overview"
        case .detail:
            "Detail"
        case .reconnect:
            "Reconnect"
        case .diagnostics:
            "Diagnostics"
        case .settings:
            "Settings"
        case .widget:
            "Widget"
        }
    }
}

public struct ValidationGalleryRoute: Equatable, Hashable, Identifiable, Sendable {
    private static let allowedSchemes = Set(["contextpanel", "contextpanelcompanion"])
    private static let allowedQueryNames = Set(["fixture", "family", "appearance", "presentation"])

    public let fixtureID: ValidationFixtureID
    public let family: ValidationGalleryFamily
    public let appearance: ValidationGalleryAppearance
    public let presentation: ValidationGalleryPresentation

    public var id: String {
        [fixtureID.rawValue, family.rawValue, appearance.rawValue, presentation.rawValue]
            .joined(separator: ":")
    }

    public init(
        fixtureID: ValidationFixtureID = .healthy,
        family: ValidationGalleryFamily = .systemMedium,
        appearance: ValidationGalleryAppearance = .adaptive,
        presentation: ValidationGalleryPresentation = .widget
    ) {
        self.fixtureID = fixtureID
        self.family = family
        self.appearance = appearance
        self.presentation = presentation
    }

    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              Self.allowedSchemes.contains(scheme),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil
        else {
            return nil
        }

        let host = components.host?.lowercased()
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let isDirectRoute = host == "validation-gallery" && path.isEmpty
        let isSettingsRoute = host == "settings" && path == "validation-gallery"
        guard isDirectRoute || isSettingsRoute else { return nil }

        let queryItems = components.queryItems ?? []
        guard queryItems.allSatisfy({ Self.allowedQueryNames.contains($0.name) }) else { return nil }

        var values: [String: String] = [:]
        for item in queryItems {
            guard values[item.name] == nil,
                  let value = item.value,
                  !value.isEmpty
            else {
                return nil
            }
            values[item.name] = value
        }

        let fixtureID: ValidationFixtureID
        if let rawFixture = values["fixture"] {
            guard let parsed = ValidationFixtureID(rawValue: rawFixture) else { return nil }
            fixtureID = parsed
        } else {
            fixtureID = .healthy
        }

        let family: ValidationGalleryFamily
        if let rawFamily = values["family"] {
            guard let parsed = ValidationGalleryFamily(rawValue: rawFamily) else { return nil }
            family = parsed
        } else {
            family = .systemMedium
        }

        let appearance: ValidationGalleryAppearance
        if let rawAppearance = values["appearance"] {
            guard let parsed = ValidationGalleryAppearance(rawValue: rawAppearance) else { return nil }
            appearance = parsed
        } else {
            appearance = .adaptive
        }

        let presentation: ValidationGalleryPresentation
        if let rawPresentation = values["presentation"] {
            guard let parsed = ValidationGalleryPresentation(rawValue: rawPresentation) else { return nil }
            presentation = parsed
        } else {
            presentation = .widget
        }

        self.init(
            fixtureID: fixtureID,
            family: family,
            appearance: appearance,
            presentation: presentation
        )
    }

}
