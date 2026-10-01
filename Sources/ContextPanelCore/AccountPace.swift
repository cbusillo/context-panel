import Foundation

/// Pace for one account window: where the remaining share sits against an even spend
/// across the window, and when the observed burn would run it out before the reset.
public extension AccountOverview.Window {
    /// Window length from its label; nil unless the label names a fixed length.
    var duration: TimeInterval? {
        let text = label.lowercased()
        if text.contains("5-hour") || text.contains("5 hour") || text == "5h" { return 5 * 3_600 }
        if text.contains("weekly") || text.contains("7-day") || text == "week" { return 7 * 86_400 }
        if text.contains("daily") || text.contains("24-hour") { return 86_400 }
        return nil
    }

    var shortLabel: String {
        guard let duration else { return label }
        return switch duration {
        case 5 * 3_600: "5h"
        case 86_400: "Day"
        default: "Week"
        }
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
    /// Windows ordered shortest first so every row reads 5h, then Week.
    var orderedWindows: [AccountOverview.Window] {
        windows.sorted { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }
    }

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
            guard let fraction = window.remainingFraction else { continue }
            var part = "\(window.label) \(Int((fraction * 100).rounded())) percent left"
            if let reset = window.naturalResetAt { part += ", resets \(ContextPanelDateFormatting.accountReset(reset, compact: true))" }
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
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated)
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
        var day = date.timeIntervalSince(now) < 7 * 86_400 - 3_600
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
        return result
    }
}
