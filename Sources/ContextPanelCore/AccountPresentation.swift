import Foundation

/// The one source for how accounts are worded, numbered and coloured on every surface:
/// Mac app, widgets, iPhone, Watch, TV and the agent snapshot. A surface may show less,
/// never different words or numbers for the same thing.
public enum AccountTerms {
    public static let accounts = "Accounts"
    public static let settings = "Settings"
    public static let updates = "Updates"
    public static let alerts = "Alerts"
    public static let display = "Display"
    public static let name = "Name"
    public static let showInWidgets = "Show in widgets"
    public static let removeAccount = "Remove account"
    public static let removeAccountEverywhere = "Remove account everywhere"
    public static let removeAccountEverywhereTitle = "Remove account everywhere?"
    public static let removalExplanation = "This account and any lanes from its setup will disappear from all Macs and companions after their next successful sync. Credentials, home folders and history stay on each Mac."
    public static let resumeUpdates = "Resume updates"
    public static let addAccount = "Add account"
    public static let addAccountMenu = "Add account…"
    public static let advanced = "Advanced"
    public static let cancel = "Cancel"
    public static let changeCodexHome = "Change Codex home"
    public static let connectCodexHome = "Connect Codex home"
    public static let percentLeft = "% left"
    public static let left = "left"
    public static let tightest = "Tightest"
    public static let useNext = "Use next"
    public static let useLast = "Use last"
    public static let next = "NEXT"
    public static let last = "LAST"
    public static let bankedResets = "Banked resets"
    public static let bankedReset = "Banked reset"
    public static let bankedResetExpires = "Banked reset expires"
    public static let banked = "banked"
    public static let lastSeen = "last seen"
    public static let resets = "Resets"
    public static let pace = "Pace"
    public static let longWindow = "Long"
    public static let measuring = "measuring"
    public static let underPace = "under pace"
    public static let onPace = "on pace"
    public static let updated = "Updated"
    public static let nextSevenDays = "Next 7 days"
    public static let noCurrentReading = "No current reading"
    public static let noEligibleAccount = "No eligible account for Use next"
    public static let addFirstAccount = "Add your first account"
    public static let unknown = "—"
    public static func accountTiming(_ account: AccountOverview.Account, now: Date) -> String {
        if [.stale, .unavailable].contains(account.state) {
            return account.stateText + (account.windows.isEmpty ? "" : account.observedAt.map { " " + AccountPaceText.when($0, now: now) } ?? "")
        }
        guard account.isReliable else { return account.stateText }
        return account.limitingWindow.flatMap { reset($0, now: now) }.map { resets + " " + $0 } ?? account.stateText
    }
    public static func deadlineLabel(_ deadline: AccountOverview.Deadline) -> String {
        deadline.label + (deadline.state == .available ? "" : " · " + lastSeen)
    }
    /// A provider read that failed, where no saved account value stands in.
    public static let notUpdating = "Not updating"

    /// "out Fri ~11 PM": a projection, so to the hour.
    public static func runOut(_ date: Date, now: Date) -> String { "out " + AccountPaceText.approximately(date, now: now) }

    public static func bankedResetCount(_ count: Int) -> String {
        "\(count) " + (count == 1 ? bankedReset : bankedResets).lowercased()
    }

    /// "2 banked" or "2 banked, last seen".
    public static func bankedCount(_ count: Int, current: Bool) -> String {
        "\(count) \(banked)" + (current ? "" : ", \(lastSeen)")
    }

    /// A window's reset, "Assumed" when the scheduled reset passed without a new reading.
    public static func reset(_ window: AccountOverview.Window, now: Date) -> String? {
        window.naturalResetAt.map { (window.assumption == nil ? "" : "Assumed ") + AccountPaceText.when($0, now: now) }
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

    /// A window's percent left, keeping "≈" when capacity is assumed after a scheduled reset.
    public static func window(_ window: AccountOverview.Window, sign: Bool = true) -> String {
        guard window.remainingFraction != nil else { return AccountTerms.unknown }
        return (window.assumption == nil ? "" : "≈ ") + (sign ? percentWithSign(window.remainingFraction) : percent(window.remainingFraction))
    }

    /// An account's tightest percent left, with the same qualifier.
    public static func account(_ account: AccountOverview.Account, sign: Bool = true) -> String {
        guard account.remainingFraction != nil else { return AccountTerms.unknown }
        let approximate = account.windows.contains { $0.assumption != nil } ? "≈ " : ""
        return approximate + (sign ? percentWithSign(account.remainingFraction) : percent(account.remainingFraction))
    }
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
    case openAI, anthropic, google, actionFill, actionText, watchSurface, destructiveFill

    public func rgb(dark: Bool) -> (red: Double, green: Double, blue: Double) {
        let pair: ((Double, Double, Double), (Double, Double, Double)) = switch self {
        case .watchSurface: ((0, 0, 0), (0, 0, 0))
        case .surface: ((250, 250, 250), (30, 31, 34))
        case .card: ((255, 255, 255), (40, 41, 45))
        case .primary: ((17, 17, 19), (240, 241, 243))
        case .secondary: ((88, 89, 95), (172, 175, 182))
        case .tertiary: ((108, 109, 116), (142, 145, 154))
        case .line: ((0, 0, 0), (255, 255, 255))
        case .track: ((0, 0, 0), (255, 255, 255))
        case .fill: ((52, 120, 98), (88, 196, 152))
        case .available: ((31, 128, 73), (76, 201, 122))
        case .low: ((158, 92, 0), (242, 169, 59))
        case .critical: ((196, 52, 44), (255, 112, 100))
        case .saved: ((134, 104, 56), (204, 172, 110))
        case .banked: ((10, 122, 160), (92, 205, 236))
        case .next: ((36, 99, 209), (120, 169, 255))
        case .openAI: ((56, 92, 126), (107, 164, 218))
        case .anthropic: ((139, 102, 51), (220, 174, 103))
        case .google: ((35, 116, 106), (83, 183, 168))
        case .destructiveFill: ((170, 35, 30), (157, 45, 40))
        case .actionFill: ((36, 99, 209), (40, 88, 171))
        case .actionText: ((255, 255, 255), (255, 255, 255))
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

public extension AccountOverview.Account {
    /// The state word for this account: "Not updating" when a read failed and nothing was ever saved.
    var stateText: String {
        state == .unavailable && windows.isEmpty ? AccountTerms.notUpdating : state.displayText
    }

    /// Pace exists only where an account has observed burn, including matched synced window estimates.
    static func hasBurn(in overview: AccountOverview) -> Bool {
        overview.accounts.contains { $0.windows.contains { $0.burnFractionPerHour != nil } }
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

public extension UsageStatus {
    /// Provider-level status in account words, so lane and account surfaces say the same thing.
    var accountState: AccountCapacityState {
        switch self {
        case .healthy: .available
        case .close: .closeToLimit
        case .limited: .limited
        case .stale: .stale
        case .failure: .unavailable
        case .loading: .refreshing
        case .unknown: .unknown
        }
    }

    /// Lane-level status word. Accounts showing a saved value say "Saved"; a failed read with
    /// nothing saved says "Not updating".
    var displayText: String { self == .failure ? AccountTerms.notUpdating : accountState.displayText }
}
