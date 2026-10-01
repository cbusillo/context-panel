import ContextPanelCore
import SwiftUI

/// Apple TV account board in the shared account design: words, numbers, colours and marks
/// come from `AccountPresentation` in ContextPanelCore. Every tile uses fixed row heights so
/// the large percentages share one baseline across the grid. Lives in TVSupport so the TV app
/// and the macOS renderer compile the same views; the app adds focus and navigation.
public struct TVAccountAnswers: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 28) {
            TVCard(title: AccountTerms.tightest) {
                if let account = overview.closest {
                    HStack(spacing: 24) {
                        TVRing(fraction: account.remainingFraction, token: AccountTone.forAccount(account).fillToken)
                            .frame(width: 120, height: 120)
                            .overlay(VStack(spacing: -2) {
                                Text(AccountNumbers.percent(account.remainingFraction))
                                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(AccountTerms.percentLeft).font(.system(size: 15)).foregroundStyle(TVTokens.color(.secondary))
                            })
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.metadata.label).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                            HStack(spacing: 10) {
                                TVProviderMark(provider: account.metadata.provider, size: 26)
                                Text("\(account.metadata.provider.accountDisplayName) · \(account.limitingWindow?.label ?? "")")
                            }
                            .foregroundStyle(TVTokens.color(.secondary))
                            if let reset = account.limitingWindow?.naturalResetAt {
                                Text(AccountTerms.resets + " " + AccountPaceText.when(reset, now: now)).monospacedDigit()
                            }
                            if let runOut = account.earliestRunOut(now: now) {
                                Text(AccountTerms.runOut(runOut.date, now: now)).foregroundStyle(TVTokens.color(.critical))
                            }
                        }
                        .font(.system(size: 22))
                    }
                } else {
                    Text(AccountTerms.noCurrentReading).foregroundStyle(TVTokens.color(.secondary))
                }
            }
            // Per provider: the account to use next, and the provider's combined weekly room under it.
            TVCard(title: AccountTerms.useNext) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(overview.providerTotals(now: now)) { total in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 14) {
                                TVProviderMark(provider: total.provider, size: 30)
                                if let account = overview.useNext(provider: total.provider) {
                                    Text(account.metadata.label).fontWeight(.semibold).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(AccountNumbers.percentWithSign(account.remainingFraction)).fontWeight(.semibold).monospacedDigit()
                                } else {
                                    Text(AccountTerms.noEligibleAccount).foregroundStyle(TVTokens.color(.secondary)).lineLimit(1)
                                    Spacer(minLength: 8)
                                }
                            }
                            if total.isCombined {
                                Text([AccountTerms.combined + " " + AccountNumbers.percentWithSign(total.longRemaining),
                                      AccountPaceText.ratio(total.paceRatio), AccountTerms.combinedOutlook(total, now: now)].joined(separator: " · "))
                                    .font(.system(size: 18)).monospacedDigit()
                                    .foregroundStyle(TVTokens.color(total.runOut == nil ? .secondary : .critical))
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                .font(.system(size: 24))
            }
            TVCard(title: AccountTerms.bankedResets) {
                VStack(alignment: .leading, spacing: 10) {
                    if let first = overview.deadlines.first {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: AccountGlyphs.banked).foregroundStyle(TVTokens.color(.banked))
                            Text(AccountPaceText.when(first.expiresAt, now: now)).font(.system(size: 36, weight: .semibold))
                                .monospacedDigit()
                            Text(AccountPaceText.countdown(to: first.expiresAt, now: now)).foregroundStyle(TVTokens.color(.secondary))
                        }
                        Text(AccountTerms.deadlineLabel(first)).foregroundStyle(TVTokens.color(.secondary)).lineLimit(1)
                        ForEach(overview.deadlines.dropFirst().prefix(2)) { deadline in
                            HStack {
                                Text(AccountPaceText.when(deadline.expiresAt, now: now)).monospacedDigit()
                                    .frame(width: 200, alignment: .leading)
                                Text(AccountTerms.deadlineLabel(deadline)).foregroundStyle(TVTokens.color(.secondary)).lineLimit(1)
                            }
                        }
                    } else {
                        Text(AccountTerms.unknown).foregroundStyle(TVTokens.color(.secondary))
                    }
                }
                .font(.system(size: 22))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

public struct TVAccountTile: View {
    let account: AccountOverview.Account
    let isNext: Bool
    let now: Date
    let showsPace: Bool

    public init(account: AccountOverview.Account, isNext: Bool, now: Date, showsPace: Bool = true) {
        self.account = account
        self.isNext = isNext
        self.now = now
        self.showsPace = showsPace
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: account.state.glyphName).font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TVTokens.color(account.state.colorToken))
                Text(account.metadata.label).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                if isNext { TVTag(text: AccountTerms.next, token: .next) }
                if account.metadata.useLast { TVTag(text: AccountTerms.last, token: .tertiary) }
                Spacer(minLength: 8)
                TVProviderMark(provider: account.metadata.provider, size: 30)
                Text(account.metadata.provider.accountDisplayName).font(.system(size: 20))
                    .foregroundStyle(TVTokens.color(.secondary))
            }
            .frame(height: 36)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AccountNumbers.account(account, sign: false))
                    .font(.system(size: 84, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(TVTokens.color(AccountTone.forAccount(account).textToken))
                Text(AccountTerms.percentLeft).font(.system(size: 24)).foregroundStyle(TVTokens.color(.secondary))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if showsPace {
                        Text(AccountNumbers.pace(account.paceRatio(now: now))).font(.system(size: 30, weight: .semibold))
                            .monospacedDigit().foregroundStyle(TVTokens.color(AccountTone.forPace(account.paceRatio(now: now))))
                    }
                    if let runOut = account.earliestRunOut(now: now) {
                        Text(AccountTerms.runOut(runOut.date, now: now)).foregroundStyle(TVTokens.color(.critical))
                    } else if account.state.needsWord {
                        Text(account.stateText).foregroundStyle(TVTokens.color(account.state.colorToken))
                    } else if showsPace {
                        Text(AccountTerms.paceWord(account.paceRatio(now: now))).foregroundStyle(TVTokens.color(.secondary))
                    }
                }
                .font(.system(size: 20))
            }
            .frame(height: 100)
            HStack(spacing: 24) {
                ForEach(account.glanceWindows) { window in
                    TVMeter(window: window, now: now)
                }
            }
            .frame(height: 50)
            HStack(spacing: 8) {
                if let banked = account.bankedResets, banked.availableCount > 0 {
                    Image(systemName: AccountGlyphs.bankedSmall).foregroundStyle(TVTokens.color(.banked))
                    Text(AccountTerms.bankedCount(banked.availableCount, current: account.bankedState == .available))
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 20)).foregroundStyle(TVTokens.color(.secondary)).frame(height: 26)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVTokens.color(.card), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: isNext))
    }
}

/// The whole board without focus handling, for captures and Top Shelf previews.
public struct TVAccountBoard: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        let nextIDs = Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id })
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccountTerms.accounts).font(.system(size: 58, weight: .semibold))
                Spacer()
                if let updated = overview.accounts.compactMap(\.observedAt).max() {
                    Text(AccountTerms.updated + " " + AccountPaceText.when(updated, now: now)).font(.system(size: 24))
                        .foregroundStyle(TVTokens.color(.secondary))
                }
            }
            TVAccountAnswers(overview: overview, now: now)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28), count: 3), spacing: 28) {
                ForEach(overview.accounts) { account in
                    TVAccountTile(account: account, isNext: nextIDs.contains(account.id), now: now,
                                  showsPace: AccountOverview.Account.hasBurn(in: overview))
                }
            }
        }
        .foregroundStyle(TVTokens.color(.primary))
    }
}

struct TVCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(TVTokens.color(.secondary))
            content
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TVTokens.color(.card), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct TVTag: View {
    let text: String
    let token: AccountColorToken
    var body: some View {
        Text(text).font(.system(size: 14, weight: .heavy)).tracking(0.8).foregroundStyle(TVTokens.color(token))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(TVTokens.color(token), lineWidth: 1.5))
    }
}

struct TVMeter: View {
    let window: AccountOverview.Window
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.shortLabel).foregroundStyle(TVTokens.color(.secondary))
                Text(AccountNumbers.window(window)).fontWeight(.semibold)
                    .foregroundStyle(TVTokens.color(AccountTone.forRemaining(window.remainingFraction).textToken))
                Spacer(minLength: 4)
                Text(AccountTerms.reset(window, now: now) ?? "")
                    .foregroundStyle(TVTokens.color(.secondary)).lineLimit(1)
            }
            .font(.system(size: 20)).monospacedDigit()
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(TVTokens.color(.track))
                    Capsule().fill(TVTokens.color(AccountTone.forRemaining(window.remainingFraction).fillToken))
                        .frame(width: max(10, width * (window.remainingFraction ?? 0)))
                    if let even = window.evenPaceRemaining(now: now) {
                        Rectangle().fill(TVTokens.color(.primary).opacity(0.8)).frame(width: 3, height: 18)
                            .offset(x: min(width - 3, max(0, width * even - 1.5)))
                    }
                }
            }
            .frame(height: 10)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TVRing: View {
    let fraction: Double?
    let token: AccountColorToken
    var body: some View {
        ZStack {
            Circle().stroke(TVTokens.color(.track), lineWidth: 12)
            Circle().trim(from: 0, to: max(0.01, fraction ?? 0))
                .stroke(TVTokens.color(token), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(6)
    }
}

/// The provider's letter on its colour, the same mark as every other surface.
public struct TVProviderMark: View {
    let provider: Provider
    let size: CGFloat

    public init(provider: Provider, size: CGFloat) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        Text(provider.markLetter).font(.system(size: size * 0.64, weight: .bold, design: .rounded))
            .foregroundStyle(TVTokens.color(.markInk))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(TVTokens.color(provider.colorToken)))
            .accessibilityHidden(true)
    }
}

/// The TV app draws on a dark background.
public enum TVTokens {
    public static func color(_ token: AccountColorToken) -> Color {
        let value = token.rgb(dark: true)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: true))
    }
}
