import Foundation
import Testing
@testable import ContextPanelCore

@Test func runtimeBuildIdentityLoadsTheExactEmbeddedSurface() throws {
    let identity = RuntimeBuildIdentityLoader.load(
        surface: .macOSWidget,
        manifestData: try runtimeManifestData(),
        bundleIdentifier: ContextPanelLocations.widgetExtensionBundleID,
        marketingVersion: "1.0.54",
        buildNumber: "2026073101",
        executableUUIDs: [runtimeExecutableUUID()]
    )

    #expect(identity?.surface == .macOSWidget)
    #expect(identity?.platform == .macOS)
    #expect(identity?.artifactID == "macos.widget")
    #expect(identity?.build.manifestID == runtimeHash("a"))
    #expect(identity?.fingerprints.runtime == runtimeHash("d"))
    #expect(identity?.executableUUIDs == [runtimeExecutableUUID().uppercased()])
}

@Test func runtimeExecutableIdentityUsesTheLoadedMachOImage() {
    #expect(RuntimeExecutableIdentity.loadedMainExecutableUUIDs()?.isEmpty == false)
}

@Test func runtimeBuildIdentityRejectsBundleAndManifestDrift() throws {
    let data = try runtimeManifestData()

    #expect(RuntimeBuildIdentityLoader.load(
        surface: .macOSWidget,
        manifestData: data,
        bundleIdentifier: "com.example.wrong",
        marketingVersion: "1.0.54",
        buildNumber: "2026073101",
        executableUUIDs: [runtimeExecutableUUID()]
    ) == nil)
    #expect(RuntimeBuildIdentityLoader.load(
        surface: .macOSRefreshAgent,
        manifestData: data,
        bundleIdentifier: ContextPanelLocations.refreshAgentBundleID,
        marketingVersion: "1.0.54",
        buildNumber: "2026073101",
        executableUUIDs: [runtimeExecutableUUID()]
    ) == nil)

    let duplicated = try runtimeManifestData(duplicatesWidget: true)
    #expect(RuntimeBuildIdentityLoader.load(
        surface: .macOSWidget,
        manifestData: duplicated,
        bundleIdentifier: ContextPanelLocations.widgetExtensionBundleID,
        marketingVersion: "1.0.54",
        buildNumber: "2026073101",
        executableUUIDs: [runtimeExecutableUUID()]
    ) == nil)
}

@Test func runtimePresentationDigestExcludesAccountAndErrorDetails() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = runtimeWidgetSnapshot(
        now: now,
        accountID: "secret-account-a",
        accountName: "Private Account A",
        errorMessage: "token-a at /Users/private-a"
    )
    let second = runtimeWidgetSnapshot(
        now: now,
        accountID: "secret-account-b",
        accountName: "Private Account B",
        errorMessage: "token-b at /Users/private-b"
    )

    let firstDigest = RuntimePresentationDigest.widgetSnapshot(
        first,
        displayPreferences: .defaultPreferences,
        presentationMode: .widgetSystemSmall,
        presentationDate: now
    )
    let secondDigest = RuntimePresentationDigest.widgetSnapshot(
        second,
        displayPreferences: .defaultPreferences,
        presentationMode: .widgetSystemSmall,
        presentationDate: now
    )

    #expect(firstDigest == secondDigest)
    #expect(RuntimeSurfaceFingerprints.isSHA256(firstDigest))

    let receipt = RuntimeReceipt(
        session: runtimeSession(now: now),
        observedAt: now,
        processInstanceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        processSequence: 1,
        buildIdentity: runtimeIdentity(),
        trigger: .widgetTimeline,
        presentationMode: .widgetSystemSmall,
        selectedSource: .appGroupSnapshot,
        presentationDigest: firstDigest,
        stateBranch: .ready,
        outcome: .success
    )
    let encoded = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)

    #expect(!encoded.contains("secret-account"))
    #expect(!encoded.contains("Private Account"))
    #expect(!encoded.contains("token-"))
    #expect(!encoded.contains("/Users/"))
    #expect(encoded.contains("actual-runtime"))
    #expect(encoded.contains("macOS"))
    #expect(!encoded.contains("shared-view"))
    #expect(!encoded.contains("os-composited-placement"))
}

@Test func runtimeWidgetDigestIncludesPresentationPreferences() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = runtimeWidgetSnapshot(
        now: now,
        accountID: "account",
        accountName: "Account",
        errorMessage: "none"
    )
    var changedPreferences = WidgetDisplayPreferences.defaultPreferences
    changedPreferences.setMainLimit(provider: .openAI, window: .weekly, isVisible: false)

    let baseline = RuntimePresentationDigest.widgetSnapshot(
        snapshot,
        displayPreferences: .defaultPreferences,
        presentationMode: .widgetSystemSmall,
        presentationDate: now
    )
    let changed = RuntimePresentationDigest.widgetSnapshot(
        snapshot,
        displayPreferences: changedPreferences,
        presentationMode: .widgetSystemSmall,
        presentationDate: now
    )

    #expect(baseline != changed)
}

@Test func runtimeWidgetDigestIncludesVisibleTelemetryAndForecastInputs() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let baseline = runtimeWidgetSnapshot(
        now: now,
        accountID: "account",
        accountName: "Account",
        errorMessage: "none"
    )
    let promptCacheChanged = WidgetSnapshot(
        state: baseline.state,
        generatedAt: baseline.generatedAt,
        limits: baseline.limits,
        reports: baseline.reports,
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "private-account",
                accountName: "Private Account",
                observedAt: now,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 800)
            ),
        ],
        promptCacheWidgetState: .available,
        observedBurnRates: baseline.observedBurnRates,
        fastModeForecastSettings: baseline.fastModeForecastSettings,
        status: baseline.status,
        message: baseline.message
    )
    let forecastSettingsChanged = WidgetSnapshot(
        state: baseline.state,
        generatedAt: baseline.generatedAt,
        limits: baseline.limits,
        reports: baseline.reports,
        promptCacheObservations: baseline.promptCacheObservations,
        promptCacheWidgetState: baseline.promptCacheWidgetState,
        observedBurnRates: baseline.observedBurnRates,
        fastModeForecastSettings: FastModeForecastSettings(fastModeMultiplier: 3),
        status: baseline.status,
        message: baseline.message
    )

    let baselineDigest = RuntimePresentationDigest.widgetSnapshot(
        baseline,
        displayPreferences: .defaultPreferences,
        presentationMode: .widgetSystemMedium,
        presentationDate: now
    )
    let promptCacheDigest = RuntimePresentationDigest.widgetSnapshot(
        promptCacheChanged,
        displayPreferences: .defaultPreferences,
        presentationMode: .widgetSystemMedium,
        presentationDate: now
    )
    let forecastDigest = RuntimePresentationDigest.widgetSnapshot(
        forecastSettingsChanged,
        displayPreferences: .defaultPreferences,
        presentationMode: .widgetSystemMedium,
        presentationDate: now
    )

    #expect(baselineDigest != promptCacheDigest)
    #expect(baselineDigest != forecastDigest)
}

@Test func runtimeCompanionDeviceClassesMapToDistinctSurfaces() {
    #expect(RuntimeSurface.companionApp(for: .phone) == .iPhoneApp)
    #expect(RuntimeSurface.companionWidget(for: .phone) == .iPhoneWidget)
    #expect(RuntimeSurface.companionApp(for: .pad) == .iPadApp)
    #expect(RuntimeSurface.companionWidget(for: .pad) == .iPadWidget)
    #expect(RuntimeSurface.companionApp(for: .vision) == .visionOSApp)
    #expect(RuntimeSurface.companionWidget(for: .vision) == .visionOSWidget)
}

@Test func companionRuntimeEvidenceMapsSourcesAndVisibleDegradation() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let readySnapshot = runtimeWidgetSnapshot(
        now: now,
        accountID: "account",
        accountName: "Account",
        errorMessage: nil
    )
    let cloudKit = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .cloudKit),
        snapshot: readySnapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )
    let appGroup = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .appGroup),
        snapshot: readySnapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .widget,
        presentationMode: .widgetSystemMedium,
        presentationDate: now
    )
    let localCache = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .localCache),
        snapshot: readySnapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .widget,
        presentationMode: .widgetSystemMedium,
        presentationDate: now
    )
    let iCloud = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .iCloud),
        snapshot: readySnapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )
    let unknownSource = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .custom),
        snapshot: readySnapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )
    let savedAfterFailure = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .localCache, deliveryStatus: .delayed),
        snapshot: runtimeWidgetSnapshot(
            now: now,
            accountID: "account",
            accountName: "Account",
            errorMessage: "latest sync failed"
        ),
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )

    #expect(cloudKit.selectedSource == .cloudKit)
    #expect(cloudKit.stateBranch == .ready)
    #expect(cloudKit.outcome == .success)
    #expect(appGroup.selectedSource == .companionAppGroup)
    #expect(localCache.selectedSource == .companionLocalCache)
    #expect(iCloud.selectedSource == .iCloud)
    #expect(unknownSource.selectedSource == .none)
    #expect(unknownSource.outcome == .degraded)
    #expect(savedAfterFailure.stateBranch == .ready)
    #expect(savedAfterFailure.outcome == .degraded)
}

@Test func companionRuntimeDigestIsPrivateStableAndPresentationAware() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let result = runtimeCompanionLoadResult(source: .cloudKit)
    let first = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: runtimeWidgetSnapshot(
            now: now,
            accountID: "secret-a",
            accountName: "Private A",
            errorMessage: "token-a at /Users/private-a"
        ),
        displayPreferences: .defaultPreferences,
        appearanceSettings: CompanionAppearanceSettings(
            visionOSAppAppearance: .dark,
            visionOSWidgetAppearance: .matchApp
        ),
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )
    let privateDetailsChanged = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: runtimeWidgetSnapshot(
            now: now,
            accountID: "secret-b",
            accountName: "Private B",
            errorMessage: "token-b at /Users/private-b"
        ),
        displayPreferences: .defaultPreferences,
        appearanceSettings: CompanionAppearanceSettings(
            visionOSAppAppearance: .dark,
            visionOSWidgetAppearance: .matchApp
        ),
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )
    let appearanceChanged = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: runtimeWidgetSnapshot(
            now: now,
            accountID: "secret-a",
            accountName: "Private A",
            errorMessage: "token-a at /Users/private-a"
        ),
        displayPreferences: .defaultPreferences,
        appearanceSettings: CompanionAppearanceSettings(
            visionOSAppAppearance: .light,
            visionOSWidgetAppearance: .matchApp
        ),
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )
    let deliveryChanged = CompanionRuntimeReceiptEvidence(
        result: runtimeCompanionLoadResult(source: .cloudKit, deliveryStatus: .delayed),
        snapshot: runtimeWidgetSnapshot(
            now: now,
            accountID: "secret-a",
            accountName: "Private A",
            errorMessage: "token-a at /Users/private-a"
        ),
        displayPreferences: .defaultPreferences,
        appearanceSettings: CompanionAppearanceSettings(
            visionOSAppAppearance: .dark,
            visionOSWidgetAppearance: .matchApp
        ),
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: now
    )

    #expect(first.presentationDigest == privateDetailsChanged.presentationDigest)
    #expect(first.presentationDigest != appearanceChanged.presentationDigest)
    #expect(first.presentationDigest != deliveryChanged.presentationDigest)
    #expect(RuntimeSurfaceFingerprints.isSHA256(first.presentationDigest))
}

@Test func companionRuntimeDigestStabilizesNoDocumentPresentations() {
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
    let secondDate = firstDate.addingTimeInterval(120)
    let result = CompanionSyncLoadResult(document: nil, status: .unknown)
    let first = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: WidgetSnapshot.fromCompanionSync(result, now: firstDate),
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: firstDate
    )
    let second = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: WidgetSnapshot.fromCompanionSync(result, now: secondDate),
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        presentationDate: secondDate
    )

    #expect(first.presentationDigest == second.presentationDigest)
    #expect(first.selectedSource == .none)
    #expect(first.stateBranch == .setupNeeded)
    #expect(first.outcome == .degraded)
}

@Test func companionRuntimeDigestTracksTVModeAndVisibleErrors() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let result = runtimeCompanionLoadResult(source: .cloudKit)
    let snapshot = runtimeWidgetSnapshot(
        now: now,
        accountID: "account",
        accountName: "Account",
        errorMessage: nil
    )
    let fullDetail = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: snapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        tvPresentationMode: .fullDetail,
        presentationDate: now
    )
    let projectOnly = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: snapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        tvPresentationMode: .projectOnly,
        presentationDate: now
    )
    let visibleError = CompanionRuntimeReceiptEvidence(
        result: result,
        snapshot: snapshot,
        displayPreferences: .defaultPreferences,
        appearanceSettings: nil,
        presentationSurface: .app,
        presentationMode: .appOverview,
        tvPresentationMode: .fullDetail,
        additionalVisibleError: true,
        presentationDate: now
    )

    #expect(fullDetail.presentationDigest != projectOnly.presentationDigest)
    #expect(fullDetail.outcome == .success)
    #expect(visibleError.presentationDigest != fullDetail.presentationDigest)
    #expect(visibleError.outcome == .degraded)
}

@Test func runtimeSessionStoreLoadsTheOperatorSchema() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionURL = root.appending(path: "runtime-session.json")
    try """
    {
      "createdAt": "2023-11-14T22:12:20Z",
      "enabledSurfaces": ["macos.widget"],
      "expectedManifestID": "\(runtimeHash("a"))",
      "expiresAt": "2023-11-14T22:43:20Z",
      "id": "10000000-0000-0000-0000-000000000001",
      "maximumReceiptCount": 128,
      "minimumWriteIntervalSeconds": 30,
      "receiptTTLSeconds": 86400,
      "schemaVersion": 1
    }
    """.write(to: sessionURL, atomically: true, encoding: .utf8)

    let session = RuntimeValidationSessionStore(sessionURL: sessionURL).activeSession(
        for: runtimeIdentity(),
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(session?.enabledSurfaces == [.macOSWidget])
    #expect(session?.expectedManifestID == runtimeHash("a"))
}

@Test func runtimeReceiptRecorderRequiresAnActiveExactBuildSession() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    let recorder = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: RuntimeReceiptProcessContext(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
    )

    #expect(runtimeRecord(recorder, at: now) == .inactiveSession)
    try sessionStore.save(runtimeSession(now: now, manifestID: runtimeHash("9")))
    #expect(runtimeRecord(recorder, at: now) == .inactiveSession)
    try sessionStore.save(runtimeSession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        now: now
    ))
    #expect(runtimeRecord(recorder, at: now) == .saved)

    let receipts = receiptStore.loadReceipts()
    #expect(receipts.count == 1)
    #expect(receipts.first?.buildIdentity == runtimeIdentity())
    #expect(receipts.first?.processSequence == 1)
    #expect(receipts.first?.evidenceClass == .actualRuntime)
}

@Test func runtimeReceiptRecorderRateLimitsOnlyEquivalentState() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    try sessionStore.save(runtimeSession(now: now, minimumWriteIntervalSeconds: 60))
    let recorder = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore
    )

    #expect(runtimeRecord(recorder, at: now) == .saved)
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(10)) == .rateLimited)
    #expect(recorder.record(
        trigger: .widgetTimeline,
        presentationMode: .widgetSystemSmall,
        selectedSource: .appGroupSnapshot,
        presentationDigest: runtimeHash("7"),
        stateBranch: .ready,
        outcome: .success,
        observedAt: now.addingTimeInterval(11)
    ) == .saved)
    #expect(recorder.record(
        trigger: .widgetTimeline,
        presentationMode: .widgetSystemSmall,
        selectedSource: .appGroupSnapshot,
        presentationDigest: runtimeHash("8"),
        stateBranch: .stale,
        outcome: .degraded,
        observedAt: now.addingTimeInterval(12)
    ) == .saved)
    #expect(receiptStore.loadReceipts().count == 3)
}

@Test func runtimeReceiptRecorderDoesNotThrottleANewLoadedExecutable() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    try sessionStore.save(runtimeSession(now: now, minimumWriteIntervalSeconds: 60))
    let first = RuntimeReceiptRecorder(
        identity: runtimeIdentity(executableUUID: runtimeExecutableUUID()),
        sessionStore: sessionStore,
        receiptStore: receiptStore
    )
    let second = RuntimeReceiptRecorder(
        identity: runtimeIdentity(executableUUID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
        sessionStore: sessionStore,
        receiptStore: receiptStore
    )

    #expect(runtimeRecord(first, at: now) == .saved)
    #expect(runtimeRecord(second, at: now.addingTimeInterval(1)) == .saved)
    #expect(receiptStore.loadReceipts().count == 2)
}

@Test func runtimeReceiptStoreBoundsTheSessionQueue() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    try sessionStore.save(runtimeSession(
        now: now,
        minimumWriteIntervalSeconds: 0,
        maximumReceiptCount: 2
    ))
    let recorder = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: RuntimeReceiptProcessContext(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        )
    )

    #expect(runtimeRecord(recorder, at: now) == .saved)
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(1)) == .saved)
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(2)) == .saved)

    let receipts = receiptStore.loadReceipts()
    #expect(receipts.count == 2)
    #expect(receipts.map(\.processSequence) == [2, 3])
}

@Test func runtimeReceiptPruningPreservesOtherSessions() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    let processContext = RuntimeReceiptProcessContext()
    let recorder = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: processContext
    )
    try sessionStore.save(runtimeSession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        now: now,
        minimumWriteIntervalSeconds: 0
    ))
    #expect(runtimeRecord(recorder, at: now) == .saved)

    try sessionStore.save(runtimeSession(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        now: now,
        minimumWriteIntervalSeconds: 0,
        maximumReceiptCount: 1
    ))
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(1)) == .saved)
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(2)) == .saved)

    let receipts = receiptStore.loadReceipts()
    #expect(receipts.count == 2)
    #expect(Set(receipts.map(\.sessionID)).count == 2)
}

@Test func runtimeReceiptRecordersShareProcessOrdering() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    try sessionStore.save(runtimeSession(now: now, minimumWriteIntervalSeconds: 0))
    let processContext = RuntimeReceiptProcessContext(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    )
    let first = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: processContext
    )
    let second = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: processContext
    )

    #expect(runtimeRecord(first, at: now) == .saved)
    #expect(second.record(
        trigger: .widgetTimeline,
        presentationMode: .widgetSystemSmall,
        selectedSource: .appGroupSnapshot,
        presentationDigest: runtimeHash("7"),
        stateBranch: .ready,
        outcome: .success,
        observedAt: now.addingTimeInterval(1)
    ) == .saved)

    let receipts = receiptStore.loadReceipts()
    #expect(Set(receipts.map(\.processInstanceID)) == Set([processContext.id]))
    #expect(receipts.map(\.processSequence) == [1, 2])
}

@Test func runtimeReceiptStoreAppliesAHardGlobalSafetyCap() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory),
        maximumRetainedReceiptCount: 2
    )
    let recorder = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: RuntimeReceiptProcessContext()
    )
    try sessionStore.save(runtimeSession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        now: now,
        minimumWriteIntervalSeconds: 0
    ))
    #expect(runtimeRecord(recorder, at: now) == .saved)
    try sessionStore.save(runtimeSession(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        now: now,
        minimumWriteIntervalSeconds: 0
    ))
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(1)) == .saved)
    #expect(runtimeRecord(recorder, at: now.addingTimeInterval(2)) == .saved)

    #expect(receiptStore.loadReceipts().count == 2)
}

@Test func runtimeReceiptStoreRejectsTamperedReceiptFiles() throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(
        directoryURL: root.appending(path: "receipts", directoryHint: .isDirectory)
    )
    try sessionStore.save(runtimeSession(now: now, minimumWriteIntervalSeconds: 0))
    let recorder = RuntimeReceiptRecorder(
        identity: runtimeIdentity(),
        sessionStore: sessionStore,
        receiptStore: receiptStore
    )
    #expect(runtimeRecord(recorder, at: now) == .saved)

    let receiptURL = try #require(
        FileManager.default.contentsOfDirectory(
            at: receiptStore.directoryURL,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" }
    )
    let originalData = try Data(contentsOf: receiptURL)
    var payload = try #require(
        try JSONSerialization.jsonObject(with: originalData) as? [String: Any]
    )
    var buildIdentity = try #require(payload["buildIdentity"] as? [String: Any])
    buildIdentity["executableUUIDs"] = [runtimeExecutableUUID().lowercased(), "invalid"]
    payload["buildIdentity"] = buildIdentity
    try JSONSerialization.data(withJSONObject: payload).write(to: receiptURL, options: [.atomic])
    #expect(receiptStore.loadReceipts().isEmpty)

    try originalData.write(to: receiptURL, options: [.atomic])
    payload = try #require(
        try JSONSerialization.jsonObject(with: originalData) as? [String: Any]
    )
    payload["outcome"] = "failure"
    try JSONSerialization.data(withJSONObject: payload).write(to: receiptURL, options: [.atomic])

    #expect(receiptStore.loadReceipts().isEmpty)
}

@Test func snapshotRefreshEvidenceCarriesTheExactSavedSnapshot() async throws {
    let root = try runtimeReceiptTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let accountStore = AccountConfigurationStore(
        configurationURL: root.appending(path: "accounts.json")
    )
    try accountStore.save(AccountConfigurationDocument(updatedAt: savedAt, accounts: []))
    let primary = JSONSnapshotStore(
        rootDirectory: root.appending(path: "snapshots", directoryHint: .isDirectory)
    )
    let service = SnapshotRefreshService(
        accountStore: accountStore,
        stores: SnapshotRefreshStores(primary: primary),
        promptCacheTelemetryReader: { _ in [] }
    )
    let runner = SnapshotRefreshRunner(service: service, lock: nil)
    let refreshResult = ConnectorRefreshResult(
        generatedAt: savedAt,
        reports: [
            ProviderConnectorReport(
                provider: .openAI,
                accountID: "account",
                accountName: "Account",
                generatedAt: savedAt,
                limits: [
                    UsageLimit(
                        provider: .openAI,
                        accountID: "account",
                        accountName: "Account",
                        label: "Weekly",
                        unit: .percent,
                        used: 30,
                        limit: 100,
                        lastUpdatedAt: savedAt
                    ),
                ]
            ),
        ]
    )

    let evidence = try await runner.saveMergedWithEvidence(
        refreshResult: refreshResult,
        savedAt: savedAt,
        retryFor: .zero
    )

    #expect(evidence.selectedSnapshot == primary.loadCurrent().snapshot)
    #expect(evidence.status == primary.loadCurrent().status)
    if case let .refreshed(outcome) = evidence.decision {
        #expect(outcome.storedSnapshot == evidence.selectedSnapshot)
        #expect(outcome.storedStatus == evidence.status)
    } else {
        Issue.record("expected exact saved-snapshot evidence")
    }
}

@Test func runtimeValidationSessionRejectsUnboundedOrExpiredCollection() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let identity = runtimeIdentity()

    #expect(runtimeSession(now: now).permits(identity, now: now))
    #expect(!runtimeSession(
        now: now,
        expiresAt: now.addingTimeInterval(RuntimeValidationSession.maximumDuration + 1)
    ).permits(identity, now: now))
    #expect(!runtimeSession(
        now: now,
        expiresAt: now
    ).permits(identity, now: now))
    #expect(!runtimeSession(
        now: now,
        enabledSurfaces: [.macOSApp]
    ).permits(identity, now: now))
}

private func runtimeRecord(
    _ recorder: RuntimeReceiptRecorder,
    at date: Date
) -> RuntimeReceiptRecordResult {
    recorder.record(
        trigger: .widgetTimeline,
        presentationMode: .widgetSystemSmall,
        selectedSource: .appGroupSnapshot,
        presentationDigest: runtimeHash("8"),
        stateBranch: .ready,
        outcome: .success,
        observedAt: date
    )
}

private func runtimeSession(
    id: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
    now: Date,
    expiresAt: Date? = nil,
    manifestID: String = runtimeHash("a"),
    enabledSurfaces: [RuntimeSurface] = [.macOSWidget],
    minimumWriteIntervalSeconds: TimeInterval = 30,
    maximumReceiptCount: Int = 128
) -> RuntimeValidationSession {
    RuntimeValidationSession(
        id: id,
        createdAt: now.addingTimeInterval(-60),
        expiresAt: expiresAt ?? now.addingTimeInterval(30 * 60),
        expectedManifestID: manifestID,
        enabledSurfaces: enabledSurfaces,
        minimumWriteIntervalSeconds: minimumWriteIntervalSeconds,
        maximumReceiptCount: maximumReceiptCount
    )
}

private func runtimeIdentity(
    executableUUID: String = runtimeExecutableUUID()
) -> RuntimeSurfaceBuildIdentity {
    RuntimeSurfaceBuildIdentity(
        surface: .macOSWidget,
        artifactID: "macos.widget",
        bundleIdentifier: ContextPanelLocations.widgetExtensionBundleID,
        build: RuntimeBuildCoordinate(
            marketingVersion: "1.0.54",
            buildNumber: "2026073101",
            manifestID: runtimeHash("a"),
            contractFingerprint: runtimeHash("b")
        ),
        fingerprints: RuntimeSurfaceFingerprints(
            render: runtimeHash("c"),
            runtime: runtimeHash("d"),
            placement: runtimeHash("e"),
            combined: runtimeHash("f")
        ),
        executableUUIDs: [executableUUID]
    )
}

private func runtimeWidgetSnapshot(
    now: Date,
    accountID: String,
    accountName: String,
    errorMessage: String?
) -> WidgetSnapshot {
    WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: accountID,
                accountName: accountName,
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 40,
                limit: 100,
                resetsAt: now.addingTimeInterval(3_600),
                lastUpdatedAt: now,
                confidence: .official
            ),
        ],
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: accountID,
                accountName: accountName,
                generatedAt: now,
                status: .healthy,
                errorMessage: errorMessage
            ),
        ],
        status: .healthy,
        message: errorMessage ?? "Ready",
        syncErrorMessage: errorMessage
    )
}

private func runtimeCompanionLoadResult(
    source: CompanionSyncSource,
    deliveryStatus: CompanionSyncDeliveryStatus = .healthy
) -> CompanionSyncLoadResult {
    CompanionSyncLoadResult(
        document: nil,
        status: .healthy,
        transportMetadata: CompanionSyncTransportMetadata(
            source: source,
            deliveryStatus: deliveryStatus
        )
    )
}

private func runtimeManifestData(duplicatesWidget: Bool = false) throws -> Data {
    let widget: [String: Any] = [
        "id": RuntimeSurface.macOSWidget.rawValue,
        "artifactId": "macos.widget",
        "bundleIdentifier": ContextPanelLocations.widgetExtensionBundleID,
        "fingerprints": [
            "render": runtimeHash("c"),
            "runtime": runtimeHash("d"),
            "placement": runtimeHash("e"),
            "combined": runtimeHash("f"),
        ],
    ]
    return try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1,
        "kind": "context-panel-surface-build-intent",
        "manifestId": runtimeHash("a"),
        "contractFingerprint": runtimeHash("b"),
        "surfaces": duplicatesWidget ? [widget, widget] : [widget],
    ])
}

private func runtimeHash(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func runtimeExecutableUUID() -> String {
    "11111111-2222-3333-4444-555555555555"
}

private func runtimeReceiptTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ContextPanelRuntimeReceiptTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
