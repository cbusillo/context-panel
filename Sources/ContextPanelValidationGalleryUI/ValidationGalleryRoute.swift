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

public struct ValidationGalleryRoute: Equatable, Hashable, Identifiable, Sendable {
    private static let allowedSchemes = Set(["contextpanel", "contextpanelcompanion"])
    private static let allowedQueryNames = Set(["fixture", "family", "appearance"])

    public let fixtureID: ValidationFixtureID
    public let family: ValidationGalleryFamily
    public let appearance: ValidationGalleryAppearance

    public var id: String {
        [fixtureID.rawValue, family.rawValue, appearance.rawValue].joined(separator: ":")
    }

    public init(
        fixtureID: ValidationFixtureID = .healthy,
        family: ValidationGalleryFamily = .systemMedium,
        appearance: ValidationGalleryAppearance = .adaptive
    ) {
        self.fixtureID = fixtureID
        self.family = family
        self.appearance = appearance
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

        self.init(fixtureID: fixtureID, family: family, appearance: appearance)
    }
}
