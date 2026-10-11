import AppKit
import SwiftUI
import Vision

import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelWatchSupport
import ContextPanelValidationGalleryUI

private let watchAccountNow = Date(timeIntervalSince1970: 1_800_000_000)

private func watchAccountOverview(
    used: [Int?] = [80, 20],
    observedAt: Date = watchAccountNow,
    now: Date = watchAccountNow,
    hidden: Bool = false,
    burn: Double? = nil
) -> AccountOverview {
    let limits = used.enumerated().map { index, used in
        UsageLimit(provider: .openAI, accountID: "sample-\(index)", accountName: "Sample \(index)",
                   label: "Weekly", windowLabel: "Weekly", unit: .percent, used: used, limit: 100,
                   resetsAt: watchAccountNow.addingTimeInterval(86_400), lastUpdatedAt: observedAt)
    }
    let metadata = limits.enumerated().map { index, limit in
        let id = AccountDisplayMetadata.safeID(limit.provider, limit.accountID)
        return AccountDisplayMetadata(id: id, configurationID: id, provider: limit.provider,
                                      label: limit.accountName, showInWidgets: !(hidden && index == 0))
    }
    let rates: [String: [String: ObservedBurnRate]] = burn.map { burn in
        [limits[0].accountID: [limits[0].id: ObservedBurnRate(limitID: limits[0].id,
            unitsPerHour: burn, observedDurationHours: 6, sampleCount: 10)]]
    } ?? [:]
    return AccountOverview(snapshot: UsageSnapshot(generatedAt: observedAt, limits: limits), reports: [],
                           metadata: metadata, now: now, widgetsOnly: true, accountBurnRates: rates)
}

@Test func watchComplicationsShowSharedUseNextAccountUnlessAnotherRunsOutFirst() throws {
    let healthy = watchAccountOverview()
    let next = try #require(WatchAccountComplicationPresentation(overview: healthy, now: watchAccountNow))
    #expect(next.account.id == healthy.useNext(provider: .openAI)?.id)
    #expect(next.horizon.remaining == 0.8)
    #expect(next.quantity == AccountNumbers.window(next.horizon.window!))
    #expect(next.circularQuantity == AccountNumbers.window(next.horizon.window!, sign: false))

    let risky = watchAccountOverview(burn: 10)
    let firstOut = try #require(WatchAccountComplicationPresentation(overview: risky, now: watchAccountNow))
    #expect(firstOut.account.id == risky.runningShort(now: watchAccountNow).first?.account.id)
    #expect(firstOut.horizon.runsOutBeforeReset)
    #expect(firstOut.account.id != next.account.id)
}

@Test func watchComplicationsRespectHiddenAccountsAndRepresentUnknownWithoutZero() throws {
    let hidden = watchAccountOverview(hidden: true, burn: 10)
    let visible = try #require(WatchAccountComplicationPresentation(overview: hidden, now: watchAccountNow))
    #expect(visible.account.metadata.label == "Sample 1")
    let unknown = try #require(WatchAccountComplicationPresentation(
        overview: watchAccountOverview(used: [nil]), now: watchAccountNow))
    #expect(unknown.horizon.remaining == nil)
    #expect(unknown.quantity == AccountTerms.unknown)
    #expect(unknown.circularQuantity == AccountTerms.unknown)
    #expect(unknown.stateSymbol != nil)
    #expect(unknown.inlineText.contains(unknown.account.stateText))
    #expect(unknown.cornerLabel.contains(unknown.account.stateText))
}

@Test func watchComplicationsPreserveSavedCapacityAndMarkItAtThePresentationDate() throws {
    let later = watchAccountNow.addingTimeInterval(SnapshotFreshness.appMaximumAge + 1)
    let overview = watchAccountOverview(used: [40], now: later)
    let saved = try #require(WatchAccountComplicationPresentation(overview: overview, now: later))
    #expect(saved.horizon.remaining == 0.6)
    #expect(!saved.horizon.isCurrent)
    #expect(saved.colorToken == .saved)
    #expect(saved.stateSymbol != nil)
    #expect(saved.inlineText.contains(saved.account.stateText))
    #expect(saved.cornerLabel.contains(saved.account.stateText))
    #expect(saved.accessibilityText.contains(AccountTerms.lastSeen))
    #expect(saved.quantity == AccountNumbers.window(saved.horizon.window!))
}

@Test func watchGalleryExercisesAccountViewsWithTheExistingSyntheticData() throws {
    let adapter = WatchValidationFixtureAdapter()
    let healthy = adapter.appContext(state: .denseAccounts)
    let metadata = try #require(healthy.snapshot.accountDisplayMetadata)
    #expect(metadata.count > 1)
    let overview = healthy.snapshot.accountOverview(now: healthy.presentationDate)
    #expect(overview.accounts.map(\.metadata) == metadata)
    #expect(overview.accounts.allSatisfy { !$0.windows.isEmpty })
    let stale = adapter.appContext(state: .stale)
    let saved = stale.snapshot.accountOverview(now: stale.presentationDate)
    #expect(!saved.accounts.isEmpty)
    #expect(saved.accounts.allSatisfy { !$0.isReliable })
    #expect(saved.accounts.contains { !$0.windows.isEmpty })
    let complication = adapter.complicationContext(state: .available)
    #expect(complication.snapshot.accountDisplayMetadata != nil)
    let missing = adapter.appContext(state: .setupNeeded)
    #expect(missing.result.document == nil)
    #expect(missing.snapshot.limits.isEmpty)
}

@MainActor
@Test(arguments: [156, 198], [false, true])
func watchRowsKeepNamesCapacityAndSavedStateVisible(width: Int, saved: Bool) throws {
    let name = "Sample deliberately long work account"
    let now = watchAccountNow.addingTimeInterval(saved ? SnapshotFreshness.appMaximumAge + 1 : 0)
    let limit = UsageLimit(provider: .openAI, accountID: "sample-row", accountName: name,
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 78, limit: 100,
        resetsAt: watchAccountNow.addingTimeInterval(86_400), lastUpdatedAt: watchAccountNow)
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: watchAccountNow, limits: [limit]), reports: [], now: now)
    let account = try #require(overview.accounts.first)
    let horizon = account.horizon(now: now)
    let renderer = ImageRenderer(content: WatchAccountRow(account: account, isNext: true, now: now)
        .padding(8).frame(width: CGFloat(width)).foregroundStyle(.white).background(.black)
        .environment(\.colorScheme, .dark))
    renderer.scale = 3
    let image = try #require(renderer.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    for word in name.split(separator: " ") { #expect(text.contains(word), "Visible row: \(text)") }
    let window = try #require(horizon.window)
    #expect(text.contains(AccountNumbers.window(window)), "Visible row: \(text)")
    #expect(text.contains(AccountTerms.horizonLeft(window)), "Visible row: \(text)")
    #expect(text.contains(AccountTerms.useNext) == !saved, "Visible row: \(text)")
    if saved {
        #expect(text.contains(AccountCapacityState.stale.displayText), "Visible row: \(text)")
    } else {
        #expect(text.contains(AccountTerms.resets), "Visible row: \(text)")
    }
}

@Test(arguments: [nil as Double?, 10.0])
func watchSavedFocusKeepsTheLastGoodAccountInsteadOfMetadataOrder(burn: Double?) throws {
    let fresh = try #require(WatchAccountComplicationPresentation(
        overview: watchAccountOverview(burn: burn), now: watchAccountNow))
    let later = watchAccountNow.addingTimeInterval(SnapshotFreshness.appMaximumAge + 1)
    let saved = try #require(WatchAccountComplicationPresentation(
        overview: watchAccountOverview(now: later, burn: burn), now: later))
    #expect(saved.account.id == fresh.account.id)
    #expect(saved.quantity == fresh.quantity)
    #expect(!saved.horizon.isCurrent)
}

@Test func watchSpeechLeadsWithTheDisplayedWindowAndNamesTheTighterShortWindow() throws {
    let limits = [("Weekly", 40), ("5-hour", 90)].map { label, used in
        UsageLimit(provider: .openAI, accountID: "sample-speech", accountName: "Sample Work",
            label: label, windowLabel: label, unit: .percent, used: used, limit: 100,
            resetsAt: watchAccountNow.addingTimeInterval(3_600), lastUpdatedAt: watchAccountNow)
    }
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: watchAccountNow, limits: limits), reports: [], now: watchAccountNow)
    let presentation = try #require(WatchAccountComplicationPresentation(overview: overview, now: watchAccountNow))
    let window = try #require(presentation.horizon.window)
    let first = window.label + " " + presentation.quantity + " " + AccountTerms.left
    #expect(presentation.accessibilityText.hasPrefix(presentation.account.metadata.provider.accountDisplayName
        + ", " + presentation.account.metadata.label + ", " + first))
    let short = try #require(presentation.account.shortWindow)
    #expect(presentation.accessibilityText.contains(short.label + " " + AccountNumbers.window(short) + " " + AccountTerms.left))
}

@Test func watchAssumedResetUsesExplicitAssumptionInsteadOfSavedOrAvailable() throws {
    let limit = UsageLimit(provider: .google, accountID: "sample-assumed", accountName: "Sample Google",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 78, limit: 100,
        resetsAt: watchAccountNow.addingTimeInterval(-1), lastUpdatedAt: watchAccountNow.addingTimeInterval(-100),
        freshnessMode: .eventDriven)
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: watchAccountNow, limits: [limit]), reports: [], now: watchAccountNow)
    let presentation = try #require(WatchAccountComplicationPresentation(overview: overview, now: watchAccountNow))
    #expect(presentation.horizon.window?.assumption == .scheduledReset)
    #expect(presentation.inlineText.contains(AccountTerms.assumed))
    #expect(presentation.cornerLabel.contains(AccountTerms.assumed))
    #expect(presentation.accessibilityText.contains(UsagePresentationAssumption.scheduledReset.accessibilityText))
    #expect(presentation.stateSymbol != nil)
    #expect(presentation.stateSymbol != WatchAccountComplicationPresentation(
        overview: watchAccountOverview(now: watchAccountNow.addingTimeInterval(SnapshotFreshness.appMaximumAge + 1)),
        now: watchAccountNow.addingTimeInterval(SnapshotFreshness.appMaximumAge + 1))?.stateSymbol)
}

@Test(arguments: [false, true])
func watchFailedAndStaleFocusReplaysTheOriginalRankingTime(failed: Bool) throws {
    let limits = [("soon", 60, 24.0), ("later", 30, 144.0)].map { id, used, hours in
        UsageLimit(provider: .openAI, accountID: id, accountName: id, label: "Weekly", windowLabel: "Weekly",
            unit: .percent, used: used, limit: 100, resetsAt: watchAccountNow.addingTimeInterval(hours * 3_600),
            lastUpdatedAt: watchAccountNow)
    }
    func overview(now: Date, status: UsageStatus) -> AccountOverview {
        let reports = limits.map { limit in StoredProviderReport(provider: limit.provider, accountID: limit.accountID,
            accountName: limit.accountName, generatedAt: watchAccountNow, status: status,
            errorMessage: status == .failure ? "Sample failure" : nil) }
        return AccountOverview(snapshot: UsageSnapshot(generatedAt: watchAccountNow, limits: limits), reports: reports, now: now)
    }
    let before = try #require(WatchAccountComplicationPresentation(overview: overview(now: watchAccountNow, status: .healthy), now: watchAccountNow))
    #expect(before.account.metadata.label == "soon")
    let afterDate = watchAccountNow.addingTimeInterval(2 * 86_400)
    let saved = overview(now: afterDate, status: failed ? .failure : .healthy)
    let after = try #require(WatchAccountComplicationPresentation(overview: saved, now: afterDate))
    #expect(after.account.id == before.account.id)
    #expect(after.quantity == before.quantity)
    #expect(!after.horizon.isCurrent)
    #expect(saved.lastObservedSelection().rankedAt == watchAccountNow)
    #expect(saved.accounts.allSatisfy { !$0.isReliable })
}

@Test func watchSavedClosestDoesNotSwitchWhenEveryShortWindowBlocksUseNext() throws {
    let limits = [0, 1].flatMap { index in ["Weekly", "5-hour"].map { window in
        UsageLimit(provider: .openAI, accountID: "blocked-\(index)", accountName: "Blocked \(index)", label: window,
            windowLabel: window, unit: .percent, used: window == "Weekly" ? 10 : 99 - index,
            limit: 100, resetsAt: watchAccountNow.addingTimeInterval(86_400), lastUpdatedAt: watchAccountNow)
    } }
    func overview(_ now: Date) -> AccountOverview {
        AccountOverview(snapshot: UsageSnapshot(generatedAt: watchAccountNow, limits: limits), reports: [], now: now)
    }
    let fresh = overview(watchAccountNow)
    #expect(fresh.useNext(provider: .openAI) == nil)
    let before = try #require(WatchAccountComplicationPresentation(overview: fresh, now: watchAccountNow))
    let later = watchAccountNow.addingTimeInterval(SnapshotFreshness.appMaximumAge + 1)
    let after = try #require(WatchAccountComplicationPresentation(overview: overview(later), now: later))
    #expect(after.account.id == before.account.id)
}

@Test func watchUnknownSpeechUsesAStateWordInsteadOfReadingTheDash() throws {
    let presentation = try #require(WatchAccountComplicationPresentation(overview: watchAccountOverview(used: [nil]), now: watchAccountNow))
    #expect(presentation.accessibilityText.contains(AccountCapacityState.unknown.displayText))
    #expect(!presentation.accessibilityText.contains(AccountTerms.unknown))
}

@MainActor
@Test(arguments: [40, 50])
func watchCircularKeepsAssumedCapacityVisibleInsideSmallRing(side: Int) throws {
    let limit = UsageLimit(provider: .google, accountID: "sample-fit", accountName: "Sample fit",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 78, limit: 100,
        resetsAt: watchAccountNow.addingTimeInterval(-1), lastUpdatedAt: watchAccountNow.addingTimeInterval(-100),
        freshnessMode: .eventDriven)
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: watchAccountNow, limits: [limit]), reports: [], now: watchAccountNow)
    let presentation = try #require(WatchAccountComplicationPresentation(overview: overview, now: watchAccountNow))
    let renderer = ImageRenderer(content: WatchAccountCircularFace(overview: overview, now: watchAccountNow)
        .frame(width: CGFloat(side), height: CGFloat(side)).background(.black).environment(\.colorScheme, .dark))
    renderer.scale = 4
    let image = try #require(renderer.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    #expect(text.contains(AccountNumbers.percent(presentation.horizon.remaining)), "Visible circular capacity: \(text)")
}
