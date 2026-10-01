import Foundation

/// The one source for how accounts are worded, numbered and coloured on every surface:
/// Mac app, widgets, iPhone, Watch, TV and the agent snapshot. A surface may show less,
/// never different words or numbers for the same thing.
public enum AccountTerms {
    public static let accounts = "Accounts"
    public static let percentLeft = "% left"
    public static let left = "left"
    public static let tightest = "Tightest"
    public static let useNext = "Use next"
    public static let useLast = "Use last"
    public static let next = "NEXT"
    public static let last = "LAST"
    public static let bankedResets = "Banked resets"
    public static let bankedResetExpires = "Banked reset expires"
    public static let banked = "banked"
    public static let lastSeen = "last seen"
    public static let resets = "Resets"
    public static let pace = "Pace"
    public static let measuring = "measuring"
    public static let underPace = "under pace"
    public static let onPace = "on pace"
    public static let updated = "Updated"
    public static let nextSevenDays = "Next 7 days"
    public static let noCurrentReading = "No current reading"
    public static let noEligibleAccount = "No account has room in every window"
    public static let addFirstAccount = "Add your first account"
    public static let unknown = "—"

    /// "out Fri ~11 PM": a projection, so to the hour.
    public static func runOut(_ date: Date, now: Date) -> String { "out " + AccountPaceText.approximately(date, now: now) }

    /// "2 banked" or "2 banked, last seen".
    public static func bankedCount(_ count: Int, current: Bool) -> String {
        "\(count) \(banked)" + (current ? "" : ", \(lastSeen)")
    }

    /// Short window column name.
    public static func windowShortName(_ window: AccountOverview.Window) -> String { window.shortLabel }

    public static func paceWord(_ ratio: Double?) -> String {
        guard let ratio else { return measuring }
        return ratio < 0.95 ? underPace : onPace
    }
}

/// Numbers: whole percent left, never "used"; pace as a one-decimal multiple.
public enum AccountNumbers {
    /// "15", "<1", "—".
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return AccountTerms.unknown }
        if fraction > 0, fraction < 0.01 { return "<1" }
        return "\(Int((fraction * 100).rounded()))"
    }

    /// "15%".
    public static func percentWithSign(_ fraction: Double?) -> String {
        fraction == nil ? AccountTerms.unknown : percent(fraction) + "%"
    }

    public static func pace(_ ratio: Double?) -> String { AccountPaceText.ratio(ratio) }
}

/// How much headroom a window or account has. Bars, rings and numbers take their colour from this.
public enum AccountTone: String, Codable, Sendable {
    case fine, low, critical, saved, unknown

    public static func forRemaining(_ fraction: Double?) -> Self {
        guard let fraction else { return .unknown }
        return fraction <= 0.10 ? .critical : fraction <= 0.25 ? .low : .fine
    }

    public static func forAccount(_ account: AccountOverview.Account) -> Self {
        switch account.state {
        case .stale, .unavailable: .saved
        case .limited: .critical
        case .notConnected, .off, .unknown: .unknown
        default: forRemaining(account.remainingFraction)
        }
    }

    public static func forPace(_ ratio: Double?) -> AccountColorToken {
        guard let ratio else { return .tertiary }
        return ratio > 1.15 ? .critical : ratio > 0.95 ? .low : .primary
    }

    public var fillToken: AccountColorToken {
        switch self {
        case .fine: .fill
        case .low: .low
        case .critical: .critical
        case .saved: .saved
        case .unknown: .tertiary
        }
    }

    /// Numbers stay primary while fine; only trouble is coloured.
    public var textToken: AccountColorToken { self == .fine ? .primary : fillToken }
}

/// Colour tokens as sRGB, light and dark. Every text token meets WCAG AA (4.5:1) on `surface` and `card`.
public enum AccountColorToken: String, CaseIterable, Sendable {
    case surface, card, primary, secondary, tertiary, line, track
    case fill, available, low, critical, saved, banked, next

    public func rgb(dark: Bool) -> (red: Double, green: Double, blue: Double) {
        let pair: ((Double, Double, Double), (Double, Double, Double)) = switch self {
        case .surface: ((250, 250, 250), (30, 31, 34))
        case .card: ((255, 255, 255), (40, 41, 45))
        case .primary: ((17, 17, 19), (240, 241, 243))
        case .secondary: ((88, 89, 95), (172, 175, 182))
        case .tertiary: ((108, 109, 116), (142, 145, 154))
        case .line: ((0, 0, 0), (255, 255, 255))
        case .track: ((0, 0, 0), (255, 255, 255))
        case .fill: ((52, 120, 98), (88, 196, 152))
        case .available: ((31, 138, 76), (76, 201, 122))
        case .low: ((158, 92, 0), (242, 169, 59))
        case .critical: ((196, 52, 44), (255, 112, 100))
        case .saved: ((134, 104, 56), (204, 172, 110))
        case .banked: ((10, 122, 160), (92, 205, 236))
        case .next: ((36, 99, 209), (120, 169, 255))
        }
        let value = dark ? pair.1 : pair.0
        return (value.0 / 255, value.1 / 255, value.2 / 255)
    }

    public func opacity(dark: Bool) -> Double {
        switch self {
        case .line: dark ? 0.10 : 0.08
        case .track: dark ? 0.13 : 0.09
        default: 1
        }
    }
}

public extension AccountCapacityState {
    /// SF Symbol for the status mark; shape carries status as well as colour.
    var glyphName: String {
        switch self {
        case .available: "circle.fill"
        case .closeToLimit: "triangle.fill"
        case .limited: "octagon.fill"
        case .stale, .unavailable: "clock.fill"
        case .refreshing: "arrow.clockwise"
        default: "circle.dashed"
        }
    }

    var colorToken: AccountColorToken {
        switch self {
        case .available: .available
        case .closeToLimit: .low
        case .limited: .critical
        case .stale, .unavailable: .saved
        default: .tertiary
        }
    }

    /// Normal states are carried by the mark alone; unusual ones are also spelled out.
    var needsWord: Bool { ![.available, .closeToLimit].contains(self) }
}

public enum AccountGlyphs {
    public static let banked = "arrow.counterclockwise.circle.fill"
    public static let bankedSmall = "arrow.counterclockwise"
    public static let bankedExpiry = "diamond.fill"
    public static let runOut = "exclamationmark.triangle.fill"
    public static let useNext = "arrow.right.circle.fill"
}
