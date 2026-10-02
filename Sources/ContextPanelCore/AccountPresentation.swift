import Foundation

/// The one source for how accounts are worded, numbered and coloured on every surface:
/// Mac app, widgets, iPhone, Watch, TV and the agent snapshot. A surface may show less,
/// never different words or numbers for the same thing.
public enum AccountTerms {
    /// The app's name. Widgets carry it as their header: on the desktop nothing else says which
    /// app a widget belongs to, and every widget already shows accounts.
    public static let appName = "Context Panel"
    public static let widgetTitle = appName
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
    // Provider totals.
    public static let combined = "Combined"
    public static let week = "Week"
    public static let fiveHour = "5h"
    public static let fiveHourLong = "5-hour"
    public static let account = "Account"
    public static let lastsToReset = "lasts to reset"
    /// Column name for the long window: "Week" unless some long window is another length.
    public static func longColumn(weekly: Bool) -> String { weekly ? week : longWindow }
    /// "3 accounts", or "2 of 3 current" when some are saved, paused or not connected.
    public static func accountCount(_ total: AccountProviderTotal) -> String {
        total.countedCount == total.accountCount
            ? "\(total.accountCount) account" + (total.accountCount == 1 ? "" : "s")
            : "\(total.countedCount) of \(total.accountCount) current"
    }
    /// The combined outlook, true whatever each plan's size: "Week lasts to reset" when no account runs
    /// out before its own reset, "1 of 3 run out" (before their resets) when some do, "all out by Sat ~4 PM" when all do.
    public static func combinedOutlook(_ total: AccountProviderTotal, now: Date) -> String {
        if let date = total.allOutBy { return "all out by " + AccountPaceText.approximately(date, now: now) }
        // A known run-out is said even while a sibling is still measuring.
        if total.runningOutCount > 0 { return "\(total.runningOutCount) of \(total.countedCount) run out" }
        guard total.paceRatio != nil else { return measuring }
        return longColumn(weekly: total.longIsWeekly) + " " + lastsToReset
    }
    /// "1 of 2" beside a compact combined number when some accounts are not current; empty otherwise.
    public static func countedSuffix(_ total: AccountProviderTotal) -> String {
        total.countedCount == total.accountCount ? "" : "\(total.countedCount) of \(total.accountCount)"
    }
    // Legends and counts.
    public static let evenPaceMark = "even-pace mark"
    public static let weeklyReset = "weekly reset"
    public static let outBeforeResetLegend = "out before reset at this pace"
    public static let bankedResetExpiresLegend = "banked reset expires"
    public static func dated(_ count: Int) -> String { "\(count) dated" }
    public static func accountsCount(_ count: Int) -> String { "\(count) account" + (count == 1 ? "" : "s") }
    /// Combined burn as a share of the combined room per hour: "0.3%/h".
    public static func burn(_ perHour: Double?) -> String {
        perHour.map { String(format: "%.1f%%/h", $0 * 100) } ?? unknown
    }

    // Deadlines page.
    public static let deadlines = "Deadlines"
    public static let nextExpiry = "Next expiry"
    public static let thisWeek = "This week"
    public static let nextThirtyDays = "Next 30 days"
    public static let later = "Later"
    public static let datesUnknown = "Dates unknown"
    public static let accountsWithBanked = "Accounts"
    public static let expires = "Expires"
    public static let noDatedBankedResets = "No dated banked resets"
    /// Whether the account's own weekly reset comes before this banked reset expires: if it does,
    /// the natural reset refills the account first; if not, the banked reset is the only refill before it lapses.
    /// Only for a window that really is weekly, and "last seen" when the reading is saved.
    public static func weekResetRelation(expiresAt: Date, week: AccountOverview.Window?, current: Bool = true, now: Date) -> String? {
        guard let week, week.duration == 7 * 86_400, let weekReset = week.naturalResetAt else { return nil }
        return weekResetRelation(expiresAt: expiresAt, weekReset: weekReset, now: now).map { current ? $0 : $0 + ", " + lastSeen }
    }
    public static func weekResetRelation(expiresAt: Date, weekReset: Date?, now: Date) -> String? {
        guard let weekReset else { return nil }
        return weekReset < expiresAt
            ? "Week resets first, " + AccountPaceText.when(weekReset, now: now)
            : "Expires before week resets " + AccountPaceText.when(weekReset, now: now)
    }
    /// "1 dated", "3 without a date".
    public static func undated(_ count: Int) -> String { "\(count) without a date" }

    // Horizon: the one-sentence summary, the outcome beside each shape, and the single callout.
    public static let runsOutBeforeReset = "Runs out before reset"
    public static let toSpare = "to spare"
    /// Burn is known but the provider gave no reset time, so nothing can be said about lasting to it.
    public static let resetUnknown = "Reset time unknown"
    public static let leftOnAverage = "left on average"
    public static let weekLeft = "week left"
    public static let untouched = "untouched"
    public static let refills = "refills"
    public static let horizonLegendLeft = "what is left, draining at your pace"
    public static let horizonLegendEmpty = "empty before the reset"
    public static let horizonLegendReset = "weekly reset, then full again"
    public static let bankedLapsesLegend = "banked reset lapses"
    public static let now = "Now"
    public static let thisWeekAtAGlance = "This week at a glance"
    public static let beforeItsReset = "Before its reset"

    private static func accountsNoun(_ count: Int) -> String { "\(count) account" + (count == 1 ? "" : "s") }

    /// The sentence every surface leads with, as a bold lead and a quieter rest:
    /// "2 accounts run out before they reset." / "The other 4 are fine."
    public static func headline(_ headline: AccountHeadline) -> (lead: String, rest: String) {
        let total = headline.total
        guard total > 0 else { return (addFirstAccount, "") }
        let others = headline.lastingCount + headline.measuringCount + headline.notCurrentCount
        let othersFine = headline.measuringCount == 0 && headline.notCurrentCount == 0
        if headline.shortCount > 0 {
            let lead = headline.shortCount == 1 ? "1 account runs out before it resets."
                : "\(headline.shortCount) accounts run out before they reset."
            if others == 0 { return (lead, "") }
            if othersFine { return (lead, others == 1 ? "The other one is fine." : "The other \(others) are fine.") }
            return (lead, restParts(headline))
        }
        if othersFine {
            return (total == 1 ? "Your account lasts to its reset." : "All \(total) accounts last to their reset.", "")
        }
        // Never reassure past what is measured: say how many are known to last, then the rest.
        return ("\(headline.lastingCount) of \(total) accounts last to their reset.", restParts(headline, includingLasting: false))
    }

    /// The same sentence for a widget's few words: "2 run out before reset." / "4 are fine."
    public static func compactHeadline(_ headline: AccountHeadline) -> (lead: String, rest: String) {
        guard headline.total > 0 else { return (addFirstAccount, "") }
        let others = headline.lastingCount + headline.measuringCount + headline.notCurrentCount
        if headline.shortCount > 0 {
            let lead = "\(headline.shortCount) run\(headline.shortCount == 1 ? "s" : "") out before reset."
            guard others > 0 else { return (lead, "") }
            return (lead, headline.measuringCount == 0 && headline.notCurrentCount == 0 ? "\(others) \(others == 1 ? "is" : "are") fine." : restParts(headline))
        }
        if headline.measuringCount == 0 && headline.notCurrentCount == 0 {
            return (headline.total == 1 ? "Lasts to reset." : "All \(headline.total) last to reset.", "")
        }
        return ("\(headline.lastingCount) of \(headline.total) last to reset.", restParts(headline, includingLasting: false))
    }

    private static func restParts(_ headline: AccountHeadline, includingLasting: Bool = true) -> String {
        var parts: [String] = []
        if includingLasting, headline.lastingCount > 0 { parts.append("\(headline.lastingCount) last\(headline.lastingCount == 1 ? "s" : "") to reset") }
        if headline.measuringCount > 0 { parts.append("\(headline.measuringCount) \(measuring)") }
        if headline.notCurrentCount > 0 { parts.append("\(headline.notCurrentCount) not current") }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
    }

    /// "~50% to spare".
    public static func spare(_ fraction: Double) -> String { "~" + AccountNumbers.percentWithSign(fraction) + " " + toSpare }
    /// "~50% spare", for widgets.
    public static func spareShort(_ fraction: Double) -> String { "~" + AccountNumbers.percentWithSign(fraction) + " spare" }
    /// "Runs out Fri ~11 PM".
    public static func runsOut(_ date: Date, now: Date) -> String { "Runs out " + AccountPaceText.approximately(date, now: now) }
    /// "Out Fri ~11 PM", for widgets.
    public static func outShort(_ date: Date, now: Date) -> String { "Out " + AccountPaceText.approximately(date, now: now) }

    /// The outcome beside a horizon: what happens before the reset, then the fact it rests on.
    /// "Runs out Fri ~11 PM" / "Empty 3½ days until it resets Tue 2:07 PM";
    /// "~50% to spare" / "Resets Sat 9:07 PM"; "measuring" / "Resets …"; or the state word for a reading
    /// that is not current.
    public static func outcome(_ account: AccountOverview.Account, _ horizon: AccountHorizon, now: Date) -> (title: String, detail: String) {
        guard horizon.isCurrent else { return (account.stateText, accountTiming(account, now: now)) }
        let resetText = horizon.window.flatMap { reset($0, now: now) }
        let name = horizon.window.flatMap(horizonWindowName)
        if let runOut = horizon.runOutAt, let empty = horizon.emptyFor {
            return ((name.map { $0 + " " } ?? "") + runsOut(runOut, now: now),
                    "Empty " + AccountPaceText.span(empty) + (resetText.map { " until it resets " + $0 } ?? ""))
        }
        let detail = resetText.map { (name.map { $0 + " resets " } ?? resets + " ") + $0 } ?? ""
        if let spare = horizon.spare { return (self.spare(spare), detail) }
        return (horizon.burnPerHour != nil && horizon.resetAt == nil ? resetUnknown : measuring, detail)
    }

    /// The compact outcome: "Out Fri ~11 PM", "~50% spare", "measuring", or the state word.
    public static func outcomeShort(_ account: AccountOverview.Account, _ horizon: AccountHorizon, now: Date) -> String {
        guard horizon.isCurrent else { return account.stateText }
        if let runOut = horizon.runOutAt { return outShort(runOut, now: now) }
        return horizon.spare.map(spareShort) ?? (horizon.burnPerHour != nil && horizon.resetAt == nil ? resetUnknown : measuring)
    }

    /// The horizon window's name when it is not the account-wide week ("Opus · Week", "Day"); nil for the plain week.
    public static func horizonWindowName(_ window: AccountOverview.Window) -> String? {
        window.modelLabel == nil && window.duration == 7 * 86_400 ? nil : window.shortLabel
    }

    /// "week left", or "Opus · Week left" when the horizon follows a model-only or other-length window.
    public static func horizonLeft(_ window: AccountOverview.Window?) -> String {
        window.flatMap(horizonWindowName).map { $0 + " " + left } ?? weekLeft
    }

    /// Why the use-next account: "Resets Sat 9:07 PM · ~50% to spare".
    public static func useNextReason(_ account: AccountOverview.Account, _ horizon: AccountHorizon, now: Date) -> String {
        [horizon.window.flatMap { window in reset(window, now: now).map { (horizonWindowName(window).map { $0 + " resets " } ?? resets + " ") + $0 } },
         horizon.spare.map(spare)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The 5-hour ring's caption: "refills 4:17 PM", or "untouched" when nothing is used.
    public static func refill(_ window: AccountOverview.Window, now: Date) -> String {
        if let fraction = window.remainingFraction, fraction >= 0.995, window.assumption == nil { return untouched }
        return reset(window, now: now).map { refills + " " + $0 } ?? unknown
    }

    /// A provider group's summary: "3 accounts · 59% left on average · 0.3%/h", then its outlook, which is red only
    /// when some account runs out before its reset.
    public static func providerSummary(_ total: AccountProviderTotal, now: Date) -> (facts: String, outlook: String, isShort: Bool) {
        var facts = [accountCount(total)]
        if total.isCombined, let long = total.longRemaining { facts.append(AccountNumbers.percentWithSign(long) + " " + leftOnAverage) }
        if total.isCombined, let burn = total.burnPerHour { facts.append(self.burn(burn)) }
        let outlook = total.runningOutCount > 0
            ? "\(total.runningOutCount) of \(total.countedCount) run\(total.runningOutCount == 1 ? "s" : "") out before reset"
            : combinedOutlook(total, now: now)
        return (facts.joined(separator: " · "), outlook, total.runningOutCount > 0)
    }

    /// For the callout: "Banked reset lapses Fri 2:27 PM, before it runs out".
    public static func bankedBeforeRunOut(_ deadline: AccountOverview.Deadline, now: Date) -> String {
        "Banked reset lapses " + AccountPaceText.when(deadline.expiresAt, now: now) + ", before it runs out"
    }

    // Horizon Deadlines agenda.

    public static let deadlinesKickerRest = "the next 7 days, then later"
    public static let today = "Today"
    public static let tomorrow = "Tomorrow"
    public static let afterThisWeek = "after this week"
    public static let bankedResetLapses = "Banked reset lapses"
    public static let runsOutTitle = "Runs out"
    public static let backToFull = "Resets, back to full"
    public static func resetsUnused(_ fraction: Double) -> String { "Resets with ~" + AccountNumbers.percentWithSign(fraction) + " unused" }
    public static func lapsesBeforeRunOut(_ seconds: TimeInterval) -> String {
        "Lapses about " + AccountPaceText.span(seconds) + " before this account runs out, so spending it before then loses nothing"
    }
    /// "6 dated banked resets · 2 this week, 5 in the next 30 days · next lapses Fri 2:27 PM, in 1d 0h · 0 without a date".
    public static func deadlinesSummary(dated: Int, thisWeek: Int, month: Int, undated: Int, next: AccountOverview.Deadline?, now: Date) -> String {
        var parts = ["\(dated) dated banked reset" + (dated == 1 ? "" : "s")]
        if dated > 0 { parts.append("\(thisWeek) this week, \(month) in the next 30 days") }
        if let next {
            parts.append("next lapses " + AccountPaceText.when(next.expiresAt, now: now) + ", " + AccountPaceText.countdown(to: next.expiresAt, now: now))
        }
        parts.append(AccountTerms.undated(undated))
        return parts.joined(separator: " · ")
    }
    public static let deadlinesGlanceKey = "Each lane runs from now to one week out; the vertical mark is the weekly reset."

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
    case fill, available, low, critical, saved, banked, next, nextSurface
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
        // The calm surface of a "use next" card.
        case .nextSurface: ((232, 242, 252), (38, 63, 89))
        // Provider identity (Horizon): teal OpenAI, ochre Claude, violet Google. Used for the provider's
        // name, its group tint and its horizon fill; never for status. Each is a text colour at 4.5:1 or
        // better on `surface`, `card` and `nextSurface`.
        case .openAI: ((12, 112, 98), (60, 196, 174))
        case .anthropic: ((150, 88, 20), (227, 166, 92))
        case .google: ((106, 75, 214), (184, 168, 255))
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

public extension Provider {
    var colorToken: AccountColorToken {
        switch self {
        case .openAI: .openAI
        case .anthropic: .anthropic
        case .google: .google
        }
    }
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
