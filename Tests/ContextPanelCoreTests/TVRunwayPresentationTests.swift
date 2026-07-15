import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import Testing

@Test func tvRunwayPresentationPoolsAccountsByProviderWindow() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let presentation = TVRunwayPresentation(
        snapshot: makeTVSnapshot(now: now),
        mode: .fullDetail,
        now: now
    )

    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })
    let weekly = try #require(openAI.lanes.first { $0.title == "Weekly" })

    #expect(weekly.remainingPercent == 70)
    #expect(weekly.capacityRatio == 0.7)
    #expect(weekly.exactCapacityText == "140 of 200 points remaining")
    #expect(weekly.accountCountText == "2 accounts")
    #expect(weekly.accountNames == ["Personal", "Work"])
    #expect(weekly.metrics.count == 2)
    #expect(openAI.accountNames == ["Personal", "Work"])
}

@Test func tvRunwayPresentationMarksAssumedScheduledResetCapacity() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now.addingTimeInterval(-3_600),
        limits: [UsageLimit(
            id: "google:local:agy:gemini-weekly",
            provider: .google,
            accountID: "local",
            accountName: "Antigravity",
            label: "Gemini Weekly",
            windowLabel: "Weekly",
            modelLabel: "Gemini",
            unit: .percent,
            used: 0,
            limit: 100,
            lastUpdatedAt: now.addingTimeInterval(-3_600),
            confidence: .estimated,
            freshnessMode: .eventDriven,
            presentationAssumption: .scheduledReset
        )],
        status: .healthy,
        message: "Synced"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let lane = try #require(presentation.sections.first?.lanes.first { $0.title == "Weekly" })
    let metric = try #require(lane.metrics.first)

    #expect(lane.isAssumedAfterScheduledReset)
    #expect(lane.remainingPercentDisplayText == "≈100%")
    #expect(lane.remainingPercentAccessibilityText == "approximately 100 percent left")
    #expect(lane.resetText == "Assumed after reset")
    #expect(lane.exactCapacityText == "≈100 of 100 points remaining")
    #expect(metric.isAssumedAfterScheduledReset)
    #expect(metric.remainingPercentDisplayText == "≈100%")
    #expect(metric.remainingPercentAccessibilityText == "approximately 100 percent left")
}

@Test func tvRunwayPresentationPreservesDuplicateAccountLabelsAndSavedOrder() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "personal-a",
                accountName: "Work",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "personal-b",
                accountName: "Work",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 20,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "personal-c",
                accountName: "Personal",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 30,
                limit: 100
            ),
        ],
        status: .healthy,
        message: "Synced"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let section = try #require(presentation.sections.first { $0.provider == .openAI })
    let weekly = try #require(section.lanes.first { $0.title == "Weekly" })

    #expect(section.accountNames == ["Work", "Work", "Personal"])
    #expect(weekly.accountNames == ["Work", "Work", "Personal"])
}

@Test func tvRunwayPresentationModesRemoveSensitiveDetail() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = makeTVSnapshot(now: now)

    let projectOnly = TVRunwayPresentation(snapshot: snapshot, mode: .projectOnly, now: now)
    let projectLane = try #require(
        projectOnly.sections.first { $0.provider == .openAI }?.lanes.first { $0.title == "Weekly" }
    )
    let projectSection = try #require(projectOnly.sections.first { $0.provider == .openAI })
    #expect(projectLane.accountNames.isEmpty)
    #expect(projectSection.accountNames.isEmpty)
    #expect(projectLane.exactCapacityText == nil)
    #expect(projectLane.accountCountText == "2 accounts")
    #expect(projectLane.metrics.count == 2)
    #expect(projectLane.metrics.map(\.title) == ["Account 1 · Weekly", "Account 2 · Weekly"])
    #expect(projectLane.metrics.allSatisfy { $0.exactCapacityText == nil })
    #expect(projectLane.metrics.map(\.remainingPercent) == [80, 60])
    #expect(projectLane.metrics.allSatisfy { $0.resetText != nil && $0.accessibilityResetText != nil })
    #expect(projectLane.metrics.allSatisfy { !$0.title.contains("Personal") && !$0.title.contains("Work") })

    let countsOnly = TVRunwayPresentation(snapshot: snapshot, mode: .countsOnly, now: now)
    let countsLane = try #require(
        countsOnly.sections.first { $0.provider == .openAI }?.lanes.first { $0.title == "Weekly" }
    )
    let countsSection = try #require(countsOnly.sections.first { $0.provider == .openAI })
    #expect(countsLane.accountNames.isEmpty)
    #expect(countsSection.accountNames.isEmpty)
    #expect(countsLane.exactCapacityText == nil)
    #expect(countsLane.accountCountText == nil)
    #expect(countsLane.resetText == nil)
    #expect(countsLane.metrics.isEmpty)
}

@Test func tvRunwayHiddenNamesReuseAnonymousAccountsAcrossWindowsAndSublimits() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .anthropic,
                accountID: "personal",
                accountName: "Personal",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                modelLabel: "Claude",
                unit: .percent,
                used: 10,
                limit: 100,
                resetsAt: now.addingTimeInterval(4 * 60 * 60)
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "personal",
                accountName: "Personal",
                label: "Claude weekly",
                windowLabel: "Weekly",
                modelLabel: "Claude",
                unit: .percent,
                used: 20,
                limit: 100,
                resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "personal",
                accountName: "Personal",
                label: "Claude Sonnet weekly",
                windowLabel: "Weekly",
                modelLabel: "Sonnet",
                unit: .percent,
                used: 30,
                limit: 100,
                resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "work",
                accountName: "Work",
                label: "Claude weekly",
                windowLabel: "Weekly",
                modelLabel: "Claude",
                unit: .percent,
                used: 90,
                limit: 100,
                resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60)
            ),
        ],
        status: .close,
        message: "Synced"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .projectOnly, now: now)
    let section = try #require(presentation.sections.first { $0.provider == .anthropic })
    let fiveHour = try #require(section.lanes.first { $0.title == "5-hour" })
    let weekly = try #require(section.lanes.first { $0.title == "Weekly" })

    #expect(fiveHour.metrics.map(\.title) == ["Account 1 · 5-hour"])
    #expect(weekly.metrics.map(\.title) == [
        "Account 1 · Weekly · Claude",
        "Account 1 · Weekly · Sonnet",
        "Account 2 · Weekly",
    ])
    #expect(weekly.metrics.map(\.status) == [.healthy, .healthy, .close])
    #expect(weekly.metrics.allSatisfy { $0.exactCapacityText == nil })
    #expect(weekly.metrics.allSatisfy { !$0.title.contains("Personal") && !$0.title.contains("Work") })

    let fullDetail = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let fullDetailSection = try #require(fullDetail.sections.first { $0.provider == .anthropic })
    let fullDetailFiveHour = try #require(fullDetailSection.lanes.first { $0.title == "5-hour" })
    let fullDetailWeekly = try #require(fullDetailSection.lanes.first { $0.title == "Weekly" })
    #expect(fullDetailSection.accountNames == ["Personal", "Work"])
    #expect(fullDetailFiveHour.accountNames == ["Personal"])
    #expect(fullDetailWeekly.accountNames == ["Personal", "Work"])
}

@Test func tvRunwayPresentationKeepsStaleDataExplicit() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ready = makeTVSnapshot(now: now)
    let stale = WidgetSnapshot(
        state: .stale,
        generatedAt: ready.generatedAt,
        limits: ready.limits,
        reports: ready.reports,
        status: .stale,
        message: "Saved snapshot"
    )

    let presentation = TVRunwayPresentation(snapshot: stale, mode: .fullDetail, now: now)

    #expect(presentation.headline == "Showing saved runway")
    #expect(presentation.detail.contains("may no longer reflect current usage"))
    #expect(!presentation.sections.isEmpty)
    #expect(presentation.sections.allSatisfy { $0.status == .stale })
    #expect(presentation.sections.flatMap(\.lanes).allSatisfy { $0.status == .stale })
    #expect(
        presentation.sections
            .flatMap(\.lanes)
            .flatMap(\.metrics)
            .allSatisfy { $0.status == .stale }
    )
}

@Test func tvRunwayPresentationSurfacesRefreshFailuresBesideCapacityLanes() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ready = makeTVSnapshot(now: now)
    let personalLimit = try #require(
        ready.limits.first { $0.provider == .openAI && $0.accountName == "Personal" }
    )
    let partial = WidgetSnapshot(
        state: .ready,
        generatedAt: ready.generatedAt,
        limits: ready.limits,
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: personalLimit.accountID,
                configuredAccountID: personalLimit.configuredAccountID,
                accountName: "Personal",
                generatedAt: now,
                status: .healthy,
                errorMessage: nil
            ),
            StoredProviderReport(
                provider: .openAI,
                accountID: "team",
                configuredAccountID: "team",
                accountName: "Team",
                generatedAt: now,
                status: .failure,
                errorMessage: "Reconnect required"
            ),
        ],
        status: .failure,
        message: "One account needs attention"
    )

    let presentation = TVRunwayPresentation(snapshot: partial, mode: .fullDetail, now: now)
    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })
    let statusLane = try #require(openAI.lanes.first { $0.kind == .accountStatus })

    #expect(openAI.status == .failure)
    #expect(openAI.trackedWindowCount == 2)
    #expect(openAI.trackedWindowText == "2 limits shown")
    #expect(openAI.lanes.filter { $0.kind == .accountStatus }.count == 1)
    #expect(statusLane.title == "Team status")
    #expect(statusLane.status == .failure)
    #expect(statusLane.detailText == "No fresh capacity data")
    #expect(statusLane.accountNames == ["Team"])

    let hiddenPresentation = TVRunwayPresentation(snapshot: partial, mode: .projectOnly, now: now)
    let hiddenOpenAI = try #require(hiddenPresentation.sections.first { $0.provider == .openAI })
    let hiddenStatusLane = try #require(hiddenOpenAI.lanes.first { $0.kind == .accountStatus })
    #expect(hiddenStatusLane.title == "Account 2 status")
    #expect(hiddenStatusLane.accountNames.isEmpty)
}

@Test func tvRunwayPresentationMakesRefreshStateExplicitWithoutDroppingSavedData() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let presentation = TVRunwayPresentation(
        snapshot: makeTVSnapshot(now: now),
        mode: .fullDetail,
        isRefreshing: true,
        now: now
    )

    #expect(presentation.status == .loading)
    #expect(presentation.headline == "Checking runway")
    #expect(presentation.detail == "Refreshing usage from your Mac.")
    #expect(!presentation.sections.isEmpty)
}

@Test func tvRunwayPresentationUsesPlainSetupLanguage() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .setupNeeded,
        generatedAt: now,
        limits: [],
        status: .unknown,
        message: "Waiting"
    )

    let waiting = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let refreshing = TVRunwayPresentation(
        snapshot: snapshot,
        mode: .fullDetail,
        isRefreshing: true,
        now: now
    )

    #expect(waiting.headline == "Waiting for your Mac")
    #expect(waiting.detail == "Open Context Panel on your Mac to share usage with this Apple TV.")
    #expect(refreshing.detail == "Looking for usage from your Mac.")
}

@Test func tvRunwayPresentationDoesNotCountAccountStatusAsAWindow() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .failure,
        generatedAt: now,
        limits: [],
        reports: [
            StoredProviderReport(
                provider: .google,
                accountID: "google",
                configuredAccountID: "google",
                accountName: "Google",
                generatedAt: now,
                status: .failure,
                errorMessage: "Reconnect required"
            ),
        ],
        status: .failure,
        message: "Reconnect required"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let google = try #require(presentation.sections.first { $0.provider == .google })

    #expect(google.trackedWindowCount == 4)
    #expect(google.trackedWindowText == "4 limits shown")
    #expect(google.lanes.count == 5)
    #expect(google.primaryLane?.title == "Model capacity")
    #expect(google.primaryLane?.remainingPercent == nil)
    #expect(google.lanes.filter { $0.kind == .accountStatus }.count == 1)
}

@Test func tvRunwayPresentationKeepsSavedPrimaryAndSeparatesClosestLimit() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 85,
                limit: 100
            ),
        ],
        status: .close,
        message: "Synced"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })

    #expect(openAI.primaryLane?.title == "Weekly")
    #expect(openAI.primaryLane?.remainingPercent == 90)
    #expect(openAI.closestLane?.title == "5-hour")
    #expect(openAI.closestLane?.remainingPercent == 15)
    #expect(openAI.lanes.prefix(2).map(\.title) == ["Weekly", "5-hour"])
    #expect(openAI.secondaryLanes.map(\.title) == ["5-hour"])
    #expect(openAI.detailPrimaryLane?.title == "Weekly")
    #expect(openAI.detailSecondaryLanes.map(\.title) == ["5-hour"])
}

@Test func tvRunwayFullDetailShowsSafeEmailAccountIdentity() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "personal",
                accountName: "chris@example.com",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
        ],
        status: .healthy,
        message: "Synced"
    )

    let fullDetail = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let fullSection = try #require(fullDetail.sections.first { $0.provider == .openAI })
    #expect(fullSection.accountNames == ["chris@example.com"])
    #expect(fullSection.primaryLane?.accountNames == ["chris@example.com"])

    let hidden = TVRunwayPresentation(snapshot: snapshot, mode: .projectOnly, now: now)
    let hiddenSection = try #require(hidden.sections.first { $0.provider == .openAI })
    #expect(hiddenSection.accountNames.isEmpty)
    #expect(hiddenSection.primaryLane?.accountNames.isEmpty == true)
    #expect(hiddenSection.primaryLane?.metrics.map(\.title) == ["Account 1 · Weekly"])
    #expect(hiddenSection.primaryLane?.metrics.first?.remainingPercent == 90)
    #expect(hiddenSection.primaryLane?.metrics.first?.exactCapacityText == nil)
    #expect(hiddenSection.primaryLane?.metrics.first?.title.contains("chris@example.com") == false)

    let countsOnly = TVRunwayPresentation(snapshot: snapshot, mode: .countsOnly, now: now)
    let countsSection = try #require(countsOnly.sections.first { $0.provider == .openAI })
    #expect(countsSection.accountNames.isEmpty)
    #expect(countsSection.primaryLane?.accountNames.isEmpty == true)
}

@Test func tvRunwayPresentationFollowsSavedProviderOrder() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai",
                accountName: "OpenAI",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 85,
                limit: 100
            ),
        ],
        status: .close,
        message: "Synced"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    let fiveHourIndex = try #require(preferences.mainLimits.firstIndex {
        $0.provider == .openAI && $0.window == .fiveHour
    })
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: fiveHourIndex), toOffset: 0)

    let presentation = TVRunwayPresentation(
        snapshot: snapshot,
        preferences: preferences,
        mode: .fullDetail,
        now: now
    )
    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })

    #expect(openAI.primaryLane?.title == "5-hour")
    #expect(openAI.closestLane == nil)
    #expect(openAI.lanes.prefix(2).map(\.title) == ["5-hour", "Weekly"])
}

@Test func tvRunwayPresentationKeepsClosestCalloutOutOfSavedDetailOrder() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            tvPercentLimit(provider: .google, window: .availability, used: 10),
            tvPercentLimit(provider: .google, window: .weekly, used: 20),
            tvPercentLimit(provider: .google, window: .fiveHour, used: 30),
            tvPercentLimit(provider: .google, window: .daily, used: 85),
        ],
        status: .close,
        message: "Synced"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let google = try #require(presentation.sections.first { $0.provider == .google })

    #expect(google.primaryLane?.title == "Model capacity")
    #expect(google.closestLane?.title == "Daily")
    #expect(google.lanes.map(\.title) == [
        "Model capacity",
        "Weekly",
        "5-hour",
        "Daily",
        "Google · Model capacity",
    ])
}

@Test func tvRunwayPresentationPreservesRealNonMainFallbackCapacity() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .google,
                accountID: "google",
                accountName: "Google",
                label: "Model requests",
                unit: .requests,
                used: 40,
                limit: 100
            ),
        ],
        status: .healthy,
        message: "Synced"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let google = try #require(presentation.sections.first { $0.provider == .google })
    let fallback = try #require(google.lanes.first { $0.title == "Google · Model requests" })

    #expect(google.primaryLane?.title == "Model capacity")
    #expect(google.primaryLane?.remainingPercent == nil)
    #expect(google.lanes.map(\.title) == [
        "Model capacity",
        "Weekly",
        "5-hour",
        "Daily",
        "Google · Model requests",
    ])
    #expect(fallback.remainingPercent == 60)
    #expect(google.closestLane == nil)

    let hiddenPresentation = TVRunwayPresentation(snapshot: snapshot, mode: .projectOnly, now: now)
    let hiddenGoogle = try #require(hiddenPresentation.sections.first { $0.provider == .google })
    let hiddenFallback = try #require(
        hiddenGoogle.lanes.first { $0.title == "Account 1 · Model requests" }
    )
    #expect(hiddenFallback.metrics.map(\.title) == ["Account 1 · Model requests"])
    #expect(hiddenFallback.exactCapacityText == nil)
}

@Test func tvRunwayPresentationDoesNotRestoreHiddenMainLanes() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [tvPercentLimit(provider: .openAI, window: .weekly, used: 20)],
        status: .healthy,
        message: "Synced"
    )
    var preferences = WidgetDisplayPreferences.defaultPreferences
    for index in preferences.mainLimits.indices {
        preferences.mainLimits[index].isVisible = false
    }

    let presentation = TVRunwayPresentation(
        snapshot: snapshot,
        preferences: preferences,
        mode: .fullDetail,
        now: now
    )
    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })

    #expect(openAI.primaryLane?.title == "No limit selected")
    #expect(openAI.primaryLane?.kind == .selectionStatus)
    #expect(openAI.primaryLane?.remainingPercent == nil)
    #expect(openAI.trackedWindowCount == 0)
    #expect(openAI.closestLane == nil)
}

@Test func tvRunwayPresentationPreservesMissingSavedPrimaryAsUnknown() throws {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [tvPercentLimit(provider: .openAI, window: .fiveHour, used: 85)],
        status: .close,
        message: "Partial sync"
    )

    let presentation = TVRunwayPresentation(snapshot: snapshot, mode: .fullDetail, now: now)
    let openAI = try #require(presentation.sections.first { $0.provider == .openAI })

    #expect(openAI.primaryLane?.title == "Weekly")
    #expect(openAI.primaryLane?.remainingPercent == nil)
    #expect(openAI.closestLane?.title == "5-hour")
    #expect(openAI.lanes.prefix(2).map(\.title) == ["Weekly", "5-hour"])
    #expect(openAI.detailPrimaryLane?.title == "5-hour")
    #expect(openAI.detailPrimaryLane?.remainingPercent == 15)
    #expect(openAI.detailSecondaryLanes.map(\.title) == ["Weekly"])
}

@Test func tvSyncReceiptStoreRejectsAReceiptForAnotherDocument() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-receipt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = TVSyncReceiptStore(receiptURL: directory.appending(path: "receipt.json"))
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = makeTVDocument(now: now)
    let receivedAt = now.addingTimeInterval(42)

    try store.save(document: document, receivedAt: receivedAt)
    #expect(store.load(matching: document)?.receivedAt == receivedAt)

    let newerDocument = makeTVDocument(now: now.addingTimeInterval(60))
    #expect(store.load(matching: newerDocument) == nil)
}

@Test func tvSyncReceiptStoreRejectsAnUnsupportedSchema() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tv-receipt-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }

    let receiptURL = directory.appending(path: "receipt.json")
    let store = TVSyncReceiptStore(receiptURL: receiptURL)
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let document = makeTVDocument(now: now)

    try store.save(document: document, receivedAt: now)
    let data = try Data(contentsOf: receiptURL)
    var receiptObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    receiptObject["schemaVersion"] = TVSyncReceipt.schemaVersion + 1
    try JSONSerialization.data(withJSONObject: receiptObject).write(to: receiptURL, options: .atomic)

    #expect(store.load(matching: document) == nil)
}

@Test func tvSyncNoticePolicyUsesTransportOutcomeInsteadOfProviderStatus() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let providerFailure = CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(
            document: makeTVDocument(now: now),
            status: .failure
        ),
        outcome: CompanionRemoteSyncOutcome(succeeded: true)
    )
    let transportFailure = CompanionRemoteSyncLoadResult(
        result: CompanionSyncLoadResult(document: nil, status: .failure),
        outcome: CompanionRemoteSyncOutcome(isAvailable: false, succeeded: false)
    )

    #expect(!TVSyncNoticePolicy.shouldShowCloudUnavailable(for: providerFailure))
    #expect(TVSyncNoticePolicy.shouldShowCloudUnavailable(for: transportFailure))
}

@Test func tvLocalCacheLocationsUseTheCachesContainer() {
    let cachesDirectory = URL(fileURLWithPath: "/container/Library/Caches", isDirectory: true)
    let locations = TVLocalCacheLocations(cachesDirectory: cachesDirectory)

    #expect(locations.rootDirectory.path == "/container/Library/Caches/Context Panel")
    #expect(
        locations.companionDocumentURL.path
            == "/container/Library/Caches/Context Panel/Companion/context-panel-companion.json"
    )
    #expect(locations.receiptURL.path == "/container/Library/Caches/Context Panel/tv-sync-receipt.json")
}

private func makeTVSnapshot(now: Date) -> WidgetSnapshot {
    let document = makeTVDocument(now: now)
    return WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: document, status: document.companionStatus),
        now: now
    )
}

private func makeTVDocument(now: Date) -> CompanionSyncDocument {
    let limits = [
        UsageLimit(
            provider: .openAI,
            accountID: "personal",
            configuredAccountID: "personal",
            accountName: "Personal",
            label: "OpenAI weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 20,
            limit: 100,
            resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            confidence: .official
        ),
        UsageLimit(
            provider: .openAI,
            accountID: "work",
            configuredAccountID: "work",
            accountName: "Work",
            label: "OpenAI weekly",
            windowLabel: "Weekly",
            unit: .percent,
            used: 40,
            limit: 100,
            resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60),
            confidence: .official
        ),
        UsageLimit(
            provider: .anthropic,
            accountID: "claude",
            configuredAccountID: "claude",
            accountName: "Claude",
            label: "Claude 5-hour",
            windowLabel: "5-hour",
            unit: .percent,
            used: 82,
            limit: 100,
            resetsAt: now.addingTimeInterval(2 * 60 * 60),
            confidence: .official
        ),
    ]
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: limits)
    )
    return CompanionSyncDocument(storedSnapshot: stored, publishedAt: now)
}

private func tvPercentLimit(
    provider: Provider,
    window: MainLimitWindow,
    used: Int
) -> UsageLimit {
    UsageLimit(
        provider: provider,
        accountID: "\(provider.rawValue)-account",
        accountName: provider.displayName,
        label: "\(provider.displayName) \(window.displayName)",
        windowLabel: window.displayName,
        unit: .percent,
        used: used,
        limit: 100
    )
}
