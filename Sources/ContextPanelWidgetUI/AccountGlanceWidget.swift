import ContextPanelCore
import SwiftUI
import WidgetKit

/// Account widgets: every account's 5h and weekly room, pace, the next reset or run-out, and banked deadlines.
struct AccountGlanceWidget: View {
    @Environment(\.cpwThemeVariant) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let family: WidgetFamily
    let snapshot: WidgetSnapshot
    let links: ContextPanelWidgetLinks
    let now: Date
    let maximumAge: TimeInterval
    let showsBanked: Bool

    private var overview: AccountOverview { snapshot.accountOverview(now: now, widgetsOnly: true, maximumAge: maximumAge) }
    private var palette: GlancePalette {
        GlancePalette(dark: theme == .dark || (theme == .adaptive && colorScheme == .dark))
    }
    private var nextIDs: Set<String> {
        Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id })
    }

    var body: some View {
        let overview = overview
        Group {
            if overview.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.accountDisplayMetadata?.isEmpty == false ? "No accounts shown" : "Add your first account")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Open Context Panel to set up accounts.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            } else {
                switch family {
                case .systemSmall:
                    if overview.accounts.count <= 2 { spotlight(overview.closest ?? overview.accounts[0], overview: overview) }
                    else { ringGrid(overview) }
                case .systemLarge, .systemExtraLarge:
                    large(overview)
                default:
                    medium(overview)
                }
            }
        }
        .padding(family == .systemSmall ? 12 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.primary)
        .background(palette.surface)
    }

    // MARK: Small

    private func ringGrid(_ overview: AccountOverview) -> some View {
        let shown = Array(overview.accounts.prefix(6))
        let names = overview.shortLabels
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Accounts").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("% left").font(.system(size: 9, weight: .medium)).foregroundStyle(palette.tertiary)
            }
            LazyVGrid(columns: columns, alignment: .center, spacing: 6) {
                ForEach(shown) { account in
                    VStack(spacing: 3) {
                        ZStack {
                            GlanceRing(fraction: account.remainingFraction, color: palette.color(for: account),
                                       track: palette.track, lineWidth: 3.5)
                            Text(account.remainingFraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        .frame(width: 34, height: 34)
                        .overlay(alignment: .topTrailing) {
                            if nextIDs.contains(account.id) {
                                Circle().fill(palette.next).frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(palette.surface, lineWidth: 1.5))
                            }
                        }
                        Text(names[account.id] ?? account.metadata.label).font(.system(size: 8.5, weight: .medium)).lineLimit(1)
                            .truncationMode(.tail).foregroundStyle(palette.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(account.accessibilityText)
                }
            }
            Spacer(minLength: 0)
            if showsBanked, let deadline = overview.nextDeadline {
                bankedLine(deadline, compact: true)
            } else if let runOut = overview.accounts.compactMap({ a in a.earliestRunOut(now: now).map { (a, $0.date) } }).min(by: { $0.1 < $1.1 }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                    Text("\(runOut.0.metadata.label) out \(AccountPaceText.approximately(runOut.1, now: now))").lineLimit(1)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(palette.bad)
            }
        }
    }

    private func spotlight(_ account: AccountOverview.Account, overview: AccountOverview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                GlanceStatusMark(state: account.state, palette: palette)
                Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                ProviderTag(provider: account.metadata.provider, palette: palette)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(account.remainingText).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("left").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
            }
            ForEach(account.orderedWindows) { window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.shortLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.secondary)
                        Spacer(minLength: 0)
                        Text(window.naturalResetAt.map { AccountPaceText.when($0, now: now) } ?? "—")
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(palette.secondary)
                    }
                    GlanceMeter(window: window, now: now, palette: palette, height: 4)
                }
            }
            Spacer(minLength: 0)
            if showsBanked, let deadline = overview.nextDeadline { bankedLine(deadline, compact: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityText)
    }

    // MARK: Medium

    private func medium(_ overview: AccountOverview) -> some View {
        let showsDeadline = showsBanked && overview.nextDeadline != nil
        let rows = Array(overview.accounts.prefix(showsDeadline ? 6 : 7))
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(title: "Accounts", trailing: "Next", compact: true)
                .padding(.bottom, 4)
            ForEach(rows) { account in
                Link(destination: links.account(account.metadata.provider, id: account.id)) {
                    compactRow(account)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if showsDeadline, let deadline = overview.nextDeadline {
                Link(destination: links.deadlines) { bankedLine(deadline, compact: false, total: overview.deadlines.count) }
                    .buttonStyle(.plain)
            } else if overview.accounts.count > rows.count {
                Link("+\(overview.accounts.count - rows.count) more", destination: links.overview)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(palette.secondary)
            }
        }
    }

    private func columnHeader(title: String, trailing: String, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text("5h").frame(width: 44, alignment: .leading)
                Text("Week").frame(width: 52, alignment: .leading)
                Text(trailing).frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(palette.tertiary)
        }
    }

    private func compactRow(_ account: AccountOverview.Account) -> some View {
        HStack(spacing: 6) {
            GlanceStatusMark(state: account.state, palette: palette)
            HStack(spacing: 3) {
                Text(account.metadata.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                if nextIDs.contains(account.id) { NextMark(palette: palette) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            windowCell(account, window: fiveHour(account), width: 44)
            windowCell(account, window: weekly(account), width: 52)
            trailingTime(account).frame(width: 70, alignment: .trailing)
        }
        .frame(height: 17)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityText)
        .accessibilityHint("Opens this account")
    }

    private func windowCell(_ account: AccountOverview.Account, window: AccountOverview.Window?, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(window?.remainingFraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                .font(.system(size: 10, weight: window?.id == account.limitingWindow?.id ? .bold : .regular).monospacedDigit())
                .foregroundStyle(window.map { palette.textColor(for: $0) } ?? palette.tertiary)
                .frame(width: 20, alignment: .trailing)
            if let window { GlanceMeter(window: window, now: now, palette: palette, height: 4) }
            else { Capsule().fill(palette.track).frame(height: 4) }
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func trailingTime(_ account: AccountOverview.Account) -> some View {
        if let runOut = account.earliestRunOut(now: now) {
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7))
                Text(AccountPaceText.approximately(runOut.date, now: now)).monospacedDigit()
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.bad).lineLimit(1)
        } else if [.stale, .unavailable].contains(account.state) {
            Text(account.observedAt.map { "Saved " + AccountPaceText.when($0, now: now) } ?? "Saved")
                .font(.system(size: 9.5)).foregroundStyle(palette.stale).lineLimit(1)
        } else {
            Text(account.limitingWindow?.naturalResetAt.map { AccountPaceText.when($0, now: now) } ?? account.state.displayText)
                .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1)
        }
    }

    // MARK: Large

    private func large(_ overview: AccountOverview) -> some View {
        let rows = Array(overview.accounts.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Accounts").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("5h · Week · pace").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(palette.tertiary)
            }
            .padding(.bottom, 3)
            ForEach(rows) { account in
                Link(destination: links.account(account.metadata.provider, id: account.id)) {
                    largeRow(account)
                }
                .buttonStyle(.plain)
                if account.id != rows.last?.id { Rectangle().fill(palette.line).frame(height: 0.5) }
            }
            Spacer(minLength: 4)
            if showsBanked, !overview.deadlines.isEmpty {
                Link(destination: links.deadlines) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(overview.deadlines.prefix(3)) { deadline in
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(palette.banked)
                                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
                                    .frame(width: 84, alignment: .leading)
                                Text(AccountPaceText.countdown(to: deadline.expiresAt, now: now)).monospacedDigit()
                                    .foregroundStyle(palette.secondary).frame(width: 52, alignment: .leading)
                                Text(deadline.label).foregroundStyle(palette.secondary).lineLimit(1)
                            }
                        }
                    }
                    .font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func largeRow(_ account: AccountOverview.Account) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                GlanceStatusMark(state: account.state, palette: palette)
                Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if nextIDs.contains(account.id) { NextTag(palette: palette) }
                if let count = account.bankedResets?.availableCount, count > 0, showsBanked {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 7, weight: .bold))
                        Text("\(count)")
                    }
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.banked)
                }
                Spacer(minLength: 2)
                if let runOut = account.earliestRunOut(now: now) {
                    Text("out " + AccountPaceText.approximately(runOut.date, now: now))
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(palette.bad).lineLimit(1)
                }
                Text(AccountPaceText.ratio(account.paceRatio(now: now)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(paceColor(account)).frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 10) {
                largeWindowCell(account, window: fiveHour(account))
                largeWindowCell(account, window: weekly(account))
            }
            .padding(.leading, 14)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityText)
        .accessibilityHint("Opens this account")
    }

    private func largeWindowCell(_ account: AccountOverview.Account, window: AccountOverview.Window?) -> some View {
        HStack(spacing: 4) {
            Text(window?.remainingFraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                .font(.system(size: 11, weight: window?.id == account.limitingWindow?.id ? .bold : .medium).monospacedDigit())
                .foregroundStyle(window.map { palette.textColor(for: $0) } ?? palette.tertiary)
                .frame(width: 22, alignment: .trailing)
            if let window { GlanceMeter(window: window, now: now, palette: palette, height: 3.5) }
            Text(window?.naturalResetAt.map { AccountPaceText.when($0, now: now) } ?? "")
                .font(.system(size: 8)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1)
                .frame(width: 58, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared

    private func fiveHour(_ account: AccountOverview.Account) -> AccountOverview.Window? {
        account.windows.first { ($0.duration ?? 0) < 86_400 }
    }

    private func weekly(_ account: AccountOverview.Account) -> AccountOverview.Window? {
        account.windows.first { ($0.duration ?? 0) >= 86_400 } ?? account.windows.first { $0.duration == nil }
    }

    private func paceColor(_ account: AccountOverview.Account) -> Color {
        guard let ratio = account.paceRatio(now: now) else { return palette.tertiary }
        return ratio > 1.15 ? palette.bad : ratio > 0.95 ? palette.warn : palette.primary
    }

    private func bankedLine(_ deadline: AccountOverview.Deadline, compact: Bool, total: Int = 0) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: compact ? 9 : 10))
                .foregroundStyle(palette.banked)
            if compact {
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
                Text(AccountPaceText.countdown(to: deadline.expiresAt, now: now)).foregroundStyle(palette.secondary)
            } else {
                Text("Banked reset expires").foregroundStyle(palette.secondary)
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
                Text("· " + deadline.label).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                if total > 1 { Text("+\(total - 1)").foregroundStyle(palette.tertiary) }
            }
        }
        .font(.system(size: compact ? 9 : 9.5)).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Banked reset for \(deadline.label) expires \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))")
    }
}

// MARK: - Building blocks

struct GlancePalette {
    let dark: Bool

    private func pick(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        let value = self.dark ? dark : light
        return Color(.sRGB, red: value.0 / 255, green: value.1 / 255, blue: value.2 / 255)
    }

    var surface: Color { pick((250, 250, 250), (30, 31, 34)) }
    var primary: Color { pick((17, 17, 19), (240, 241, 243)) }
    var secondary: Color { pick((88, 89, 95), (172, 175, 182)) }
    var tertiary: Color { pick((108, 109, 116), (142, 145, 154)) }
    var line: Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    var track: Color { dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09) }
    var fill: Color { pick((52, 120, 98), (88, 196, 152)) }
    var good: Color { pick((31, 138, 76), (76, 201, 122)) }
    var warn: Color { pick((158, 92, 0), (242, 169, 59)) }
    var bad: Color { pick((196, 52, 44), (255, 112, 100)) }
    var stale: Color { pick((134, 104, 56), (204, 172, 110)) }
    var banked: Color { pick((10, 122, 160), (92, 205, 236)) }
    var next: Color { pick((36, 99, 209), (120, 169, 255)) }

    func color(forRemaining fraction: Double?) -> Color {
        guard let fraction else { return tertiary }
        return fraction <= 0.10 ? bad : fraction <= 0.25 ? warn : fill
    }

    func color(for account: AccountOverview.Account) -> Color {
        switch account.state {
        case .stale, .unavailable: stale
        case .limited: bad
        case .notConnected, .off, .unknown: tertiary
        default: color(forRemaining: account.remainingFraction)
        }
    }

    func textColor(for window: AccountOverview.Window) -> Color {
        guard let fraction = window.remainingFraction else { return tertiary }
        return fraction <= 0.10 ? bad : fraction <= 0.25 ? warn : primary
    }
}

/// Remaining share as a bar, with a tick where an even spend would be now.
struct GlanceMeter: View {
    let window: AccountOverview.Window
    let now: Date
    let palette: GlancePalette
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = window.remainingFraction ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule().fill(palette.color(forRemaining: window.remainingFraction))
                    .frame(width: max(fraction > 0 ? height : 0, width * fraction))
                if let even = window.evenPaceRemaining(now: now) {
                    Rectangle().fill(palette.primary.opacity(0.75))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: min(width - 1.5, max(0, width * even - 0.75)))
                }
            }
            .frame(height: height + 4)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

struct GlanceRing: View {
    let fraction: Double?
    let color: Color
    let track: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: max(0.015, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().stroke(track, style: StrokeStyle(lineWidth: lineWidth, dash: [2, 3]))
            }
        }
        .padding(lineWidth / 2)
    }
}

struct GlanceStatusMark: View {
    let state: AccountCapacityState
    let palette: GlancePalette

    var body: some View {
        Image(systemName: symbol).font(.system(size: 7.5, weight: .bold)).foregroundStyle(color)
            .frame(width: 9).accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .available: "circle.fill"
        case .closeToLimit: "triangle.fill"
        case .limited: "octagon.fill"
        case .stale, .unavailable: "clock.fill"
        case .refreshing: "arrow.clockwise"
        default: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .available: palette.good
        case .closeToLimit: palette.warn
        case .limited: palette.bad
        case .stale, .unavailable: palette.stale
        default: palette.tertiary
        }
    }
}

struct NextTag: View {
    let palette: GlancePalette
    var body: some View {
        Text("NEXT").font(.system(size: 6.5, weight: .heavy)).tracking(0.4)
            .foregroundStyle(palette.next)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(palette.next, lineWidth: 0.8))
            .accessibilityLabel("Use next")
    }
}

/// A small "use next" arrow for rows too narrow for the NEXT tag.
struct NextMark: View {
    let palette: GlancePalette
    var body: some View {
        Image(systemName: "arrow.right.circle.fill").font(.system(size: 8.5)).foregroundStyle(palette.next)
            .accessibilityLabel("Use next")
    }
}

struct ProviderTag: View {
    let provider: Provider
    let palette: GlancePalette
    var body: some View {
        Text(provider.accountDisplayName).font(.system(size: 8.5, weight: .medium)).foregroundStyle(palette.secondary)
    }
}
