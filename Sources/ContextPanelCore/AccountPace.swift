import Foundation

/// Pace for one account window: where the remaining share sits against an even spend
/// across the window, and when the observed burn would run it out before the reset.
public extension AccountOverview.Window {
    /// Window length from its label; nil unless the label names a fixed length.
    var duration: TimeInterval? {
        let text = (periodLabel ?? label).lowercased()
        if text.contains("5-hour") || text.contains("5 hour") || text == "5h" { return 5 * 3_600 }
        if text.contains("weekly") || text.contains("7-day") || text == "week" { return 7 * 86_400 }
        if text.contains("daily") || text.contains("24-hour") { return 86_400 }
        return nil
    }

    var shortLabel: String {
        guard let duration else { return label }
        let period = switch duration {
        case 5 * 3_600: "5h"
        case 86_400: "Day"
        default: "Week"
        }
        return modelLabel.map { $0 + " · " + period } ?? period
    }

    /// Share that would be left now if the window were spent evenly up to the reset.
    func evenPaceRemaining(now: Date) -> Double? {
        guard let duration, let reset = naturalResetAt, assumption == nil else { return nil }
        return min(1, max(0, reset.timeIntervalSince(now) / duration))
    }

    /// Observed burn divided by the burn that would land exactly on zero at the reset.
    func paceRatio(now: Date) -> Double? {
        guard let burn = burnFractionPerHour, let remaining = remainingFraction,
              let reset = naturalResetAt, reset > now else { return nil }
        guard remaining > 0 else { return burn > 0 ? .infinity : 0 }
        return burn / (remaining / (reset.timeIntervalSince(now) / 3_600))
    }

    /// When the observed burn reaches zero, if that comes before the natural reset.
    func projectedRunOut(now: Date) -> Date? {
        guard let burn = burnFractionPerHour, burn > 0, let remaining = remainingFraction,
              let reset = naturalResetAt else { return nil }
        let runOut = now.addingTimeInterval(remaining / burn * 3_600)
        return runOut < reset ? runOut : nil
    }
}

public extension AccountOverview.Account {
    /// Windows ordered longest first so every surface reads Week, then 5h: the weekly window
    /// decides how much work is left; the 5-hour window only paces it.
    var orderedWindows: [AccountOverview.Window] {
        windows.sorted { ($0.duration ?? .infinity) > ($1.duration ?? .infinity) }
    }

    /// The two columns every glance surface shows, in reading order: long (Week), then short (5h).
    var glanceWindows: [AccountOverview.Window] { [longWindow, shortWindow].compactMap { $0 } }

    /// The short column: a window under a day long.
    var shortWindow: AccountOverview.Window? {
        windows.filter { ($0.duration ?? .infinity) < 86_400 }.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
    }

    /// The long column: the tightest of every other window, so the limiting one is never hidden.
    var longWindow: AccountOverview.Window? {
        windows.filter { $0.id != shortWindow?.id }.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
    }

    /// The earliest run-out across windows, with the window that causes it. Saved data gets none.
    func earliestRunOut(now: Date) -> (window: AccountOverview.Window, date: Date)? {
        guard isReliable else { return nil }
        return windows.compactMap { window in window.projectedRunOut(now: now).map { (window, $0) } }
            .min { $0.1 < $1.1 }
    }

    /// Fastest pace across this account's windows. Saved data gets none.
    func paceRatio(now: Date) -> Double? {
        guard isReliable else { return nil }
        return windows.compactMap { $0.paceRatio(now: now) }.max()
    }

    /// Spoken summary with every window, pace and run-out.
    func glanceAccessibilityText(now: Date, isNext: Bool) -> String {
        var parts = [accessibilityText]
        for window in orderedWindows {
            guard window.remainingFraction != nil else { continue }
            var part = window.label + " " + AccountNumbers.window(window) + " " + AccountTerms.left
            if let reset = AccountTerms.reset(window, now: now) { part += ", " + AccountTerms.resets + " " + reset }
            parts.append(part)
        }
        if let ratio = paceRatio(now: now) { parts.append("pace \(AccountPaceText.ratio(ratio))") }
        if let runOut = earliestRunOut(now: now) {
            parts.append("at this pace \(runOut.window.label) runs out around \(AccountPaceText.approximately(runOut.date, now: now)), before its reset")
        }
        if isNext { parts.append("use next") }
        return parts.joined(separator: ", ")
    }
}

/// One provider's accounts side by side. Providers report percentages, not plan sizes, so the
/// combined percent, burn and pace are an index: each account counts equally. The outlook does not
/// depend on plan sizes: it says how many accounts run out before their own reset at their own
/// burn, and when the last of them does if all of them do. Only accounts with a current reading
/// count; saved, paused and unconnected accounts are listed but not added.
public struct AccountProviderTotal: Equatable, Sendable, Identifiable {
    public let provider: Provider
    public let accountCount: Int
    public let countedCount: Int
    /// Mean share left of each counted account's provider-wide weekly window, and of its 5-hour window.
    public let longRemaining: Double?
    public let shortRemaining: Double?
    public let longIsWeekly: Bool
    /// Where the combined long window would sit now at an even spend.
    public let evenPaceRemaining: Double?
    /// Combined observed burn against the burn that would land every account on zero at its reset.
    public let paceRatio: Double?
    /// Mean observed burn per hour, comparable with `longRemaining`.
    public let burnPerHour: Double?
    /// Counted accounts whose long window runs out before its own reset at its own burn.
    public let runningOutCount: Int
    /// When the last counted account runs out, if every one of them runs out before its reset.
    public let allOutBy: Date?
    public var id: String { provider.rawValue }
}

public extension AccountOverview.Account {
    /// The window an account adds to its provider's total: the tightest long window that applies to
    /// the whole account (no model name), so a model-only limit is never pooled with an overall one.
    var poolWindow: AccountOverview.Window? {
        let long = windows.filter { $0.id != shortWindow?.id }
        return long.filter { $0.modelLabel == nil }.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
            ?? longWindow
    }
}

public extension AccountProviderTotal {
    /// A combined row says something only when a provider has more than one account.
    var isCombined: Bool { accountCount > 1 }

    /// Spoken summary of the combined row, in the words the row shows.
    func accessibilityText(now: Date) -> String {
        var parts = [provider.accountDisplayName + " " + AccountTerms.combined.lowercased(), AccountTerms.accountCount(self)]
        if let longRemaining {
            parts.append(AccountTerms.longColumn(weekly: longIsWeekly) + " " + AccountNumbers.percentWithSign(longRemaining) + " " + AccountTerms.left)
        }
        if let shortRemaining { parts.append(AccountTerms.fiveHourLong + " " + AccountNumbers.percentWithSign(shortRemaining) + " " + AccountTerms.left) }
        if let paceRatio { parts.append("pace " + AccountPaceText.ratio(paceRatio)) }
        parts.append(AccountTerms.combinedOutlook(self, now: now))
        return parts.joined(separator: ", ")
    }
}

public extension AccountOverview {
    /// Combined room, pace and outlook per provider, in provider order, for providers with accounts.
    func providerTotals(now: Date) -> [AccountProviderTotal] {
        Provider.allCases.compactMap { provider in
            let all = accounts.filter { $0.metadata.provider == provider }
            guard !all.isEmpty else { return nil }
            let counted = all.filter(\.isReliable)
            let longs = counted.compactMap(\.poolWindow)
            let shorts = counted.compactMap(\.shortWindow)
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            let complete = !longs.isEmpty && longs.count == counted.count
            let evens = longs.compactMap { $0.evenPaceRemaining(now: now) }
            // Pace and outlook need every counted account's burn; a partial set would understate it.
            var pace: Double?, burn: Double?, runningOut = 0, allOutBy: Date?
            if complete, longs.allSatisfy({ $0.burnFractionPerHour != nil && $0.remainingFraction != nil && ($0.naturalResetAt ?? now) > now }) {
                let total = longs.reduce(0) { $0 + ($1.burnFractionPerHour ?? 0) }
                let even = longs.reduce(0) { sum, window in
                    sum + (window.remainingFraction ?? 0) / max(1.0 / 60, (window.naturalResetAt ?? now).timeIntervalSince(now) / 3_600)
                }
                burn = total / Double(longs.count)
                pace = even > 0 ? total / even : (total > 0 ? .infinity : 0)
                let runOuts = longs.compactMap { $0.projectedRunOut(now: now) }
                runningOut = runOuts.count
                allOutBy = runOuts.count == longs.count ? runOuts.max() : nil
            }
            return AccountProviderTotal(
                provider: provider, accountCount: all.count, countedCount: counted.count,
                longRemaining: complete ? mean(longs.compactMap(\.remainingFraction)) : nil,
                shortRemaining: !shorts.isEmpty && shorts.count == counted.count ? mean(shorts.compactMap(\.remainingFraction)) : nil,
                longIsWeekly: longs.allSatisfy { $0.duration == 7 * 86_400 },
                evenPaceRemaining: complete && evens.count == longs.count ? mean(evens) : nil,
                paceRatio: pace, burnPerHour: burn, runningOutCount: runningOut, allOutBy: allOutBy)
        }
    }
}

public enum AccountPaceText {
    public static func ratio(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        if !ratio.isFinite { return "Out" }
        if ratio < 0.05 { return "Idle" }
        return String(format: "%.1f×", ratio)
    }

    /// "in 3h 12m", "in 2d 4h"; minute precision under a day.
    public static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours)h \(minutes % 60)m" }
        return "in \(hours / 24)d \(hours % 24)h"
    }

    /// A projection, to the hour: "Fri ~11 PM".
    public static func approximately(_ date: Date, now: Date, timeZone: TimeZone = .autoupdatingCurrent,
                                     locale: Locale = .autoupdatingCurrent) -> String {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        var hour = Date.FormatStyle.dateTime.hour()
        hour.locale = locale
        hour.timeZone = timeZone
        guard !calendar.isDate(date, inSameDayAs: now) else { return "~" + date.formatted(hour) }
        let sameWeekday = calendar.component(.weekday, from: date) == calendar.component(.weekday, from: now)
        var day = !sameWeekday && abs(date.timeIntervalSince(now)) < 7 * 86_400
            ? Date.FormatStyle.dateTime.weekday(.abbreviated) : Date.FormatStyle.dateTime.month(.abbreviated).day()
        day.locale = locale
        day.timeZone = timeZone
        return date.formatted(day) + " ~" + date.formatted(hour)
    }

    /// Time only for today, weekday and time within a week, else month and day.
    public static func when(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent,
                            timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        var time = Date.FormatStyle.dateTime.hour().minute()
        time.locale = locale
        time.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        let sameWeekday = calendar.component(.weekday, from: date) == calendar.component(.weekday, from: now)
        var day = !sameWeekday && abs(date.timeIntervalSince(now)) < 7 * 86_400
            ? Date.FormatStyle.dateTime.weekday(.abbreviated) : Date.FormatStyle.dateTime.month(.abbreviated).day()
        day.locale = locale
        day.timeZone = timeZone
        return date.formatted(day) + " " + date.formatted(time)
    }
}

public extension AccountOverview {
    /// Short names for tight layouts: the local part of an email, without words every
    /// same-provider sibling shares, so "Claude primary" and "Claude backup" stay distinct.
    var shortLabels: [String: String] {
        var result: [String: String] = [:]
        for account in accounts {
            let label = account.metadata.label
            if let at = label.firstIndex(of: "@"), at > label.startIndex {
                result[account.id] = String(label[..<at])
                continue
            }
            let words = label.split(separator: " ").map(String.init)
            let others = accounts.filter { $0.id != account.id }.map { Set($0.metadata.label.split(separator: " ").map(String.init)) }
            let distinct = words.filter { word in !others.contains { $0.contains(word) } }
            result[account.id] = distinct.isEmpty || words.count == 1 ? label : distinct.joined(separator: " ")
        }
        let counts = Dictionary(grouping: result.values, by: { $0 }).mapValues(\.count)
        for account in accounts where counts[result[account.id] ?? "", default: 0] > 1 {
            result[account.id] = account.metadata.label
        }
        return result
    }
}

/// Horizon: an account's long (weekly) window as one shape that drains at the observed burn toward
/// its reset. If it reaches empty first, the gap until the reset is the only thing drawn in red.
/// Only current readings are projected; saved, paused and unconnected accounts get no projection.
public struct AccountHorizon: Equatable, Sendable {
    /// The window the shape follows: the account's long column, so the limiting window is never hidden.
    public let window: AccountOverview.Window?
    public let remaining: Double?
    public let resetAt: Date?
    /// Observed burn as a share per hour; nil while measuring or when the reading is not current.
    public let burnPerHour: Double?
    /// When the shape reaches empty, if that comes before the reset.
    public let runOutAt: Date?
    /// Share expected to be left at the reset at the observed burn; zero when it runs out first.
    public let spare: Double?
    public let isCurrent: Bool

    public var runsOutBeforeReset: Bool { runOutAt != nil }
    /// How long the account sits empty before its reset refills it.
    public var emptyFor: TimeInterval? {
        guard let runOutAt, let resetAt else { return nil }
        return resetAt.timeIntervalSince(runOutAt)
    }

    /// Share left at `date` along the projection, for drawing; flat while measuring.
    public func remaining(at date: Date, now: Date) -> Double? {
        guard let remaining else { return nil }
        guard let burnPerHour else { return remaining }
        return max(0, remaining - burnPerHour * max(0, date.timeIntervalSince(now)) / 3_600)
    }
}

public extension AccountOverview.Account {
    func horizon(now: Date) -> AccountHorizon {
        let window = longWindow
        let current = isReliable
        let reset = window?.naturalResetAt.flatMap { $0 > now ? $0 : nil }
        let burn = current ? window?.burnFractionPerHour : nil
        let runOut = current ? window?.projectedRunOut(now: now) : nil
        let spare: Double? = if runOut != nil { 0 } else if let burn, let reset, let remaining = window?.remainingFraction {
            max(0, remaining - burn * reset.timeIntervalSince(now) / 3_600)
        } else { nil }
        return AccountHorizon(window: window, remaining: window?.remainingFraction, resetAt: reset, burnPerHour: burn,
                              runOutAt: runOut, spare: spare, isCurrent: current)
    }
}

/// The one-sentence summary every surface leads with.
public struct AccountHeadline: Equatable, Sendable {
    /// Current accounts whose long window runs out before its reset.
    public let shortCount: Int
    /// Current accounts projected to last to their reset.
    public let lastingCount: Int
    /// Current accounts without observed burn yet.
    public let measuringCount: Int
    /// Saved, paused, unconnected or unknown accounts.
    public let notCurrentCount: Int
    public var total: Int { shortCount + lastingCount + measuringCount + notCurrentCount }
}

public extension AccountOverview {
    func headline(now: Date) -> AccountHeadline {
        var short = 0, lasting = 0, measuring = 0, other = 0
        for account in accounts {
            let horizon = account.horizon(now: now)
            if !horizon.isCurrent { other += 1 }
            else if horizon.runsOutBeforeReset { short += 1 }
            else if horizon.burnPerHour == nil { measuring += 1 }
            else { lasting += 1 }
        }
        return AccountHeadline(shortCount: short, lastingCount: lasting, measuringCount: measuring, notCurrentCount: other)
    }

    /// Accounts that run out before their reset, soonest first: the single callout.
    func runningShort(now: Date) -> [(account: Account, horizon: AccountHorizon)] {
        accounts.map { ($0, $0.horizon(now: now)) }.filter(\.1.runsOutBeforeReset)
            .sorted { ($0.1.runOutAt ?? .distantFuture) < ($1.1.runOutAt ?? .distantFuture) }
    }

    /// The account's banked reset that lapses before it runs out, if any: spending it first loses nothing.
    func bankedBeforeRunOut(_ account: Account, now: Date) -> Deadline? {
        guard let runOut = account.horizon(now: now).runOutAt else { return nil }
        return deadlines.first { $0.accountID == account.id && $0.state == .available && $0.expiresAt < runOut }
    }
}

public extension AccountPaceText {
    /// A span to the nearest useful unit: "40 min", "32 hours", "3½ days".
    static func span(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3_600
        if hours < 1 { return "\(max(1, Int((seconds / 60).rounded()))) min" }
        if hours < 48 { let whole = Int(hours.rounded()); return "\(whole) hour" + (whole == 1 ? "" : "s") }
        let halves = Int((hours / 12).rounded())
        return "\(halves / 2)" + (halves % 2 == 1 ? "½" : "") + " days"
    }
}

/// Where to draw a horizon across a span that starts now, as fractions: x of the span (0...1) and
/// y of the window (0...1 left). Every surface draws the same shape from this, at its own size.
public struct AccountHorizonGeometry: Equatable, Sendable {
    /// Share left now, at x = 0.
    public let startLevel: Double
    /// Where the fill ends: the run-out, else the reset, else the end of the span.
    public let fillEndX: Double
    public let fillEndLevel: Double
    /// Time spent empty before the reset: the hatched red gap.
    public let emptyRange: ClosedRange<Double>?
    /// The reset mark, when the reset falls inside the span.
    public let resetX: Double?
    /// Midnight boundaries inside the span, for faint day lines.
    public let dayXs: [Double]
    /// Banked resets lapsing inside the span, at the level the shape has then.
    public let banked: [(x: Double, level: Double)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.startLevel == rhs.startLevel && lhs.fillEndX == rhs.fillEndX && lhs.fillEndLevel == rhs.fillEndLevel
            && lhs.emptyRange == rhs.emptyRange && lhs.resetX == rhs.resetX && lhs.dayXs == rhs.dayXs
            && lhs.banked.map(\.x) == rhs.banked.map(\.x) && lhs.banked.map(\.level) == rhs.banked.map(\.level)
    }
}

public extension AccountHorizon {
    static let span: TimeInterval = 7 * 86_400

    /// Each midnight inside the span, with its x: the axis every horizon shares.
    static func days(now: Date, span: TimeInterval = AccountHorizon.span, calendar: Calendar = .current) -> [(x: Double, date: Date)] {
        (1...8).compactMap { day in
            let boundary = calendar.startOfDay(for: now).addingTimeInterval(Double(day) * 86_400)
            let value = boundary.timeIntervalSince(now) / span
            return value > 0 && value < 1 ? (value, boundary) : nil
        }
    }

    func geometry(now: Date, deadlines: [AccountOverview.Deadline] = [], span: TimeInterval = AccountHorizon.span,
                  calendar: Calendar = .current) -> AccountHorizonGeometry {
        func x(_ date: Date) -> Double { min(1, max(0, date.timeIntervalSince(now) / span)) }
        let start = remaining ?? 0
        let end = runOutAt ?? resetAt ?? now.addingTimeInterval(span)
        let endX = x(end)
        let empty = runOutAt.flatMap { runOut in resetAt.map { x(runOut)...x($0) } }
        let days = Self.days(now: now, span: span, calendar: calendar).map(\.x)
        let lapses = deadlines.filter { $0.expiresAt > now && $0.expiresAt.timeIntervalSince(now) <= span }
            .map { (x: x($0.expiresAt), level: remaining(at: $0.expiresAt, now: now) ?? 0) }
        return AccountHorizonGeometry(startLevel: start, fillEndX: endX,
                                      fillEndLevel: remaining(at: end, now: now) ?? start, emptyRange: empty,
                                      resetX: resetAt.flatMap { $0.timeIntervalSince(now) <= span ? x($0) : nil },
                                      dayXs: days, banked: lapses)
    }
}
