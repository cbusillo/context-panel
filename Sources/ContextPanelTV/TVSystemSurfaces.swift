@preconcurrency import CloudKit
import ContextPanelCloudKitSync
import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import OSLog
@preconcurrency import TVServices
import UIKit
@preconcurrency import UserNotifications

struct TVSystemSurfaceUpdate: Equatable, Sendable {
    let noticeMessage: String?
}

extension Notification.Name {
    static let contextPanelTVBackgroundSyncDidUpdateCache = Notification.Name(
        "ContextPanelTVBackgroundSyncDidUpdateCache"
    )
    static let contextPanelTVCloudKitAccountDidChange = Notification.Name(
        "ContextPanelTVCloudKitAccountDidChange"
    )
}

actor TVSystemSurfaceCoordinator {
    static let shared = TVSystemSurfaceCoordinator()
    private static let logger = Logger(
        subsystem: "com.shinycomputers.contextpanel",
        category: "TVSystemSurfaces"
    )

    private let topShelfLocations: TVTopShelfSharedLocations?
    private var contentSelection = TVSystemSurfaceContentSelection()
    private var activeUserScope: CompanionCloudKitUserScope?
    private var updateTask: Task<TVSystemSurfaceUpdate, Never>?
    private var updateSequence = 0
    private var invalidationGeneration = 0

    init(
        topShelfLocations: TVTopShelfSharedLocations? = TVTopShelfSharedLocations.live()
    ) {
        self.topShelfLocations = topShelfLocations
    }

    func update(
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        version: TVCompanionSyncVersion?,
        cloudKitUserScope: CompanionCloudKitUserScope
    ) async -> TVSystemSurfaceUpdate {
        let selectedContent = contentSelection.select(
            snapshot: snapshot,
            preferences: preferences,
            version: version,
            cloudKitUserScope: cloudKitUserScope
        )
        let previousUpdateTask = updateTask
        updateSequence += 1
        let sequence = updateSequence
        let generation = invalidationGeneration
        let task = Task {
            _ = await previousUpdateTask?.value
            return await performUpdate(selectedContent, generation: generation)
        }
        updateTask = task
        let update = await task.value
        if updateSequence == sequence {
            updateTask = nil
        }
        return update
    }

    private func performUpdate(
        _ selectedContent: TVSystemSurfaceContent,
        generation: Int
    ) async -> TVSystemSurfaceUpdate {
        guard generation == invalidationGeneration else {
            return TVSystemSurfaceUpdate(noticeMessage: nil)
        }
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: TVPreferenceKeys.presentationMode)
            .flatMap(TVPresentationMode.init(rawValue:))
            ?? .fullDetail
        let now = Date()
        var notices: [String] = []
        if let topShelfLocations {
            do {
                if activeUserScope != selectedContent.cloudKitUserScope {
                    try topShelfLocations.purgePublishedContent()
                }
                try CompanionCloudKitUserScopeStateStore(
                    stateURL: topShelfLocations.cloudKitUserScopeStateURL
                ).save(selectedContent.cloudKitUserScope, updatedAt: now)
                try TVTopShelfDocumentStore(documentURL: topShelfLocations.documentURL).save(TVTopShelfDocument(
                    snapshot: selectedContent.snapshot,
                    preferences: selectedContent.preferences,
                    mode: mode,
                    cloudKitUserScope: selectedContent.cloudKitUserScope,
                    now: now
                ))
                activeUserScope = selectedContent.cloudKitUserScope
                TVTopShelfContentProvider.topShelfContentDidChange()
            } catch {
                let error = error as NSError
                Self.logger.error(
                    "Top Shelf save failed (\(error.domain, privacy: .public) \(error.code, privacy: .public))"
                )
                notices.append("Top Shelf could not save its latest provider runway.")
            }
        } else {
            notices.append("Top Shelf shared storage is unavailable on this Apple TV.")
        }

        return TVSystemSurfaceUpdate(noticeMessage: notices.first)
    }

    func invalidateUserScope() {
        invalidationGeneration += 1
        contentSelection.reset()
        activeUserScope = nil
        if let topShelfLocations {
            try? CompanionCloudKitUserScopeStateStore(
                stateURL: topShelfLocations.cloudKitUserScopeStateURL
            ).clear()
            try? topShelfLocations.purgePublishedContent()
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}

@MainActor
final class TVRuntimeReceiptRelayProvider {
    private let makeRuntimeReceiptRelay: () -> RuntimeReceiptRelayCoordinator?
    private var runtimeReceiptRelay: RuntimeReceiptRelayCoordinator?

    init(
        makeRuntimeReceiptRelay: @escaping () -> RuntimeReceiptRelayCoordinator? = {
            RuntimeReceiptRelayCoordinator.appGroupReceiver(
                remoteStore: RuntimeReceiptCloudKitStoreFactory.make(),
                expectedManifestID: RuntimeBuildIdentityLoader.load(surface: .tvOSApp)?.build.manifestID,
                eligibleSurfaces: [.tvOSApp, .tvOSTopShelf],
                appGroupID: ContextPanelLocations.companionAppGroupID
            )
        }
    ) {
        self.makeRuntimeReceiptRelay = makeRuntimeReceiptRelay
    }

    func resolve() -> RuntimeReceiptRelayCoordinator? {
        if let runtimeReceiptRelay {
            return runtimeReceiptRelay
        }
        guard let resolved = makeRuntimeReceiptRelay() else {
            return nil
        }
        runtimeReceiptRelay = resolved
        return resolved
    }
}

@MainActor
final class ContextPanelTVAppDelegate: NSObject, UIApplicationDelegate {
    private let remoteStore = CompanionCloudKitSyncStoreFactory.make()
    let runtimeReceiptRelayProvider = TVRuntimeReceiptRelayProvider()
    private let notificationCenter = UNUserNotificationCenter.current()
    private var subscriptionRegistrationTask: Task<Void, Never>?
    private var accountChangeObserver: NSObjectProtocol?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        clearRetiredProviderBadge()
        #if DEBUG
        if preparePreviewFixtureRuntime() {
            return true
        }
        #endif
        application.registerForRemoteNotifications()
        registerCloudKitAccountChangeObserver()
        registerCloudKitSubscription()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        clearRetiredProviderBadge()
        #if DEBUG
        if preparePreviewFixtureRuntime() {
            return
        }
        #endif
        application.registerForRemoteNotifications()
        registerCloudKitSubscription()
        synchronizeRuntimeReceipts()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        UserDefaults.standard.removeObject(
            forKey: TVPreferenceKeys.remoteNotificationRegistrationError
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        let error = error as NSError
        UserDefaults.standard.set(
            "Remote notification registration failed (\(error.domain) \(error.code)).",
            forKey: TVPreferenceKeys.remoteNotificationRegistrationError
        )
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let notificationMetadata = Self.cloudKitNotificationMetadata(userInfo) else {
            completionHandler(.noData)
            return
        }
        let runtimeReceiptRelay = runtimeReceiptRelayProvider.resolve()
        Task { [remoteStore, runtimeReceiptRelay] in
            let currentUserRecordName = try? await CKContainer(
                identifier: ContextPanelLocations.iCloudContainerID
            ).userRecordID().recordName
            guard TVCloudKitNotificationPolicy.accepts(
                notificationMetadata,
                expectedSubscriptionID: CompanionRemoteSync.cloudKitSubscriptionID,
                expectedContainerIdentifier: ContextPanelLocations.iCloudContainerID,
                currentUserRecordName: currentUserRecordName
            ) else {
                completionHandler(.noData)
                return
            }
            let result = await TVBackgroundSyncCoordinator(remoteStore: remoteStore).refresh()
            completionHandler(result)
            Task { [runtimeReceiptRelay] in
                _ = await runtimeReceiptRelay?.synchronize()
            }
        }
    }

    #if DEBUG
    private func preparePreviewFixtureRuntime() -> Bool {
        guard TVPreviewFixtures.usesFixture else { return false }
        UserDefaults.standard.removeObject(forKey: TVPreferenceKeys.cloudKitSubscriptionError)
        UserDefaults.standard.removeObject(forKey: TVPreferenceKeys.remoteNotificationRegistrationError)
        return true
    }
    #endif

    private static func cloudKitNotificationMetadata(
        _ userInfo: [AnyHashable: Any]
    ) -> TVCloudKitNotificationMetadata? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return nil
        }
        guard let queryNotification = notification as? CKQueryNotification,
              CompanionCloudKitNotificationPolicy.accepts(
                  subscriptionID: queryNotification.subscriptionID,
                  recordName: queryNotification.recordID?.recordName
              ) else {
            return nil
        }
        return TVCloudKitNotificationMetadata(
            subscriptionID: notification.subscriptionID,
            containerIdentifier: notification.containerIdentifier,
            subscriptionOwnerRecordName: notification.subscriptionOwnerUserRecordID?.recordName
        )
    }

    private func registerCloudKitSubscription() {
        guard subscriptionRegistrationTask == nil else { return }
        let defaults = UserDefaults.standard

        subscriptionRegistrationTask = Task { [weak self, remoteStore] in
            let outcome = await remoteStore.registerSubscription()
            guard let self else { return }
            if outcome.succeeded {
                defaults.removeObject(forKey: TVPreferenceKeys.cloudKitSubscriptionError)
            } else {
                defaults.set(
                    outcome.errorMessage ?? "CloudKit background updates could not be registered.",
                    forKey: TVPreferenceKeys.cloudKitSubscriptionError
                )
            }
            subscriptionRegistrationTask = nil
        }
    }

    private func registerCloudKitAccountChangeObserver() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("CKAccountChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCloudKitAccountChange()
            }
        }
    }

    private func handleCloudKitAccountChange() {
        let locations = TVLocalCacheLocations.live()
        try? CompanionCloudKitUserScopeStateStore(
            stateURL: locations.cloudKitUserScopeStateURL
        ).clear()
        try? CompanionSyncStore(documentURL: locations.companionDocumentURL).remove()
        try? TVSyncReceiptStore(receiptURL: locations.receiptURL).remove()
        Task {
            await TVSystemSurfaceCoordinator.shared.invalidateUserScope()
        }
        UserDefaults.standard.removeObject(forKey: TVPreferenceKeys.cloudKitSubscriptionError)
        NotificationCenter.default.post(
            name: .contextPanelTVCloudKitAccountDidChange,
            object: nil
        )
        registerCloudKitSubscription()
    }

    private func synchronizeRuntimeReceipts() {
        let runtimeReceiptRelay = runtimeReceiptRelayProvider.resolve()
        Task { [runtimeReceiptRelay] in
            _ = await runtimeReceiptRelay?.synchronize()
        }
    }

    private func clearRetiredProviderBadge() {
        let badgeCount = TVRetiredProviderBadgeCleanup(
            providerAlertStateURL: TVLocalCacheLocations.live().providerAlertStateURL
        ).perform(
            defaults: .standard,
            removePendingNotificationRequests: { [notificationCenter] identifiers in
                notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
            }
        )
        Task { [notificationCenter] in
            try? await notificationCenter.setBadgeCount(badgeCount)
        }
    }
}

private struct TVBackgroundSyncCoordinator: Sendable {
    let remoteStore: CompanionRemoteSyncStore

    func refresh() async -> UIBackgroundFetchResult {
        let startedAt = Date()
        let initialScopeResolution = await remoteStore.currentUserScopeResolution()
        guard case let .resolved(userScope) = initialScopeResolution else {
            if initialScopeResolution == .unavailable {
                await invalidateLocalScope()
            }
            return .noData
        }
        guard await activateLocalScope(userScope, updatedAt: startedAt) else { return .failed }
        let localLocations = TVLocalCacheLocations.live()
        let stalenessPolicy = SnapshotStoreStalenessPolicy.appDefault(
            maximumAge: SnapshotFreshness.companionProviderMaximumAge
        )
        let cacheStore = CompanionSyncStore(
            documentURL: localLocations.companionDocumentURL,
            source: .localCache
        )
        let receiptStore = TVSyncReceiptStore(receiptURL: localLocations.receiptURL)
        let cachedAtStart = cacheStore.load(
            expectedUserScope: userScope,
            policy: stalenessPolicy,
            now: startedAt
        )
        let receiptAtStart = cachedAtStart.document.flatMap(receiptStore.load(matching:))
        guard let remoteLoad = await loadWithTimeout(now: startedAt) else { return .failed }
        let finalScopeResolution = await remoteStore.currentUserScopeResolution()
        guard finalScopeResolution == .resolved(userScope),
              remoteLoad.outcome.cloudKitUserScope == userScope
        else {
            if finalScopeResolution == .unavailable
                || (finalScopeResolution.userScope != nil && finalScopeResolution.userScope != userScope)
            {
                await invalidateLocalScope()
            }
            return .failed
        }
        if let document = remoteLoad.result.document,
           document.cloudKitUserScope != userScope {
            await invalidateLocalScope()
            return .failed
        }
        let completedAt = Date()
        let loaded = remoteLoad.result
        guard let document = loaded.document else {
            if remoteLoad.outcome.succeeded, remoteLoad.outcome.missingRecord {
                switch cacheStore.removeIfCurrent(
                    cachedAtStart.document,
                    policy: stalenessPolicy,
                    now: completedAt
                ) {
                case .removed:
                    try? receiptStore.removeIfCurrent(receiptAtStart)
                case let .keptCurrent(currentResult):
                    guard let currentDocument = currentResult.document,
                          currentDocument.cloudKitUserScope == userScope
                    else {
                        _ = cacheStore.removeIfCurrent(
                            currentResult.document,
                            policy: stalenessPolicy,
                            now: completedAt
                        )
                        return .noData
                    }
                    let snapshot = WidgetSnapshot.fromCompanionSync(
                        currentResult,
                        now: completedAt,
                        stalenessPolicy: stalenessPolicy
                    )
                    _ = await TVSystemSurfaceCoordinator.shared.update(
                        snapshot: snapshot,
                        preferences: currentDocument.widgetDisplayPreferences,
                        version: TVCompanionSyncVersion(document: currentDocument),
                        cloudKitUserScope: userScope
                    )
                    NotificationCenter.default.post(
                        name: .contextPanelTVBackgroundSyncDidUpdateCache,
                        object: nil
                    )
                case .failed:
                    return .failed
                }
            }
            return loaded.status == .failure ? .failed : .noData
        }

        let cacheSaveResult = cacheStore.saveResult(
            document,
            policy: stalenessPolicy,
            now: completedAt
        ) { currentResult in
            TVCompanionSyncCachePolicy.shouldKeepCurrent(
                currentResult,
                replacingWith: document
            )
        }
        let incomingVersion = TVCompanionSyncVersion(document: document)
        let publicationResult: CompanionSyncLoadResult
        let fetchResult: UIBackgroundFetchResult
        switch cacheSaveResult {
        case let .keptCurrent(currentResult):
            guard let currentDocument = currentResult.document else { return .failed }
            if TVCompanionSyncVersion(document: currentDocument) == incomingVersion {
                do {
                    try receiptStore.save(
                        document: currentDocument,
                        receivedAt: completedAt,
                        cloudKitUserScope: userScope
                    )
                } catch {
                    return .failed
                }
            }
            publicationResult = currentResult
            fetchResult = .noData
        case let .saved(saveResult):
            guard saveResult.succeeded else { return .failed }
            do {
                try receiptStore.save(
                    document: document,
                    receivedAt: completedAt,
                    cloudKitUserScope: userScope
                )
            } catch {
                return .failed
            }
            publicationResult = loaded
            fetchResult = .newData
        }

        let snapshot = WidgetSnapshot.fromCompanionSync(
            publicationResult,
            now: completedAt,
            stalenessPolicy: stalenessPolicy
        )
        guard let publicationDocument = publicationResult.document else { return .failed }
        _ = await TVSystemSurfaceCoordinator.shared.update(
            snapshot: snapshot,
            preferences: publicationDocument.widgetDisplayPreferences,
            version: TVCompanionSyncVersion(document: publicationDocument),
            cloudKitUserScope: userScope
        )
        NotificationCenter.default.post(
            name: .contextPanelTVBackgroundSyncDidUpdateCache,
            object: nil
        )
        return fetchResult
    }

    private func loadWithTimeout(now: Date) async -> CompanionRemoteSyncLoadResult? {
        await TVAsyncDeadline.value(timeout: .seconds(18)) {
            await remoteStore.load(now: now)
        }
    }

    private func activateLocalScope(
        _ userScope: CompanionCloudKitUserScope,
        updatedAt: Date
    ) async -> Bool {
        let locations = TVLocalCacheLocations.live()
        let stateStore = CompanionCloudKitUserScopeStateStore(
            stateURL: locations.cloudKitUserScopeStateURL
        )
        if stateStore.load() != userScope {
            invalidateLocalUsage()
            await TVSystemSurfaceCoordinator.shared.invalidateUserScope()
        }
        do {
            try stateStore.save(userScope, updatedAt: updatedAt)
            return true
        } catch {
            await invalidateLocalScope()
            return false
        }
    }

    private func invalidateLocalScope() async {
        let locations = TVLocalCacheLocations.live()
        try? CompanionCloudKitUserScopeStateStore(
            stateURL: locations.cloudKitUserScopeStateURL
        ).clear()
        invalidateLocalUsage()
        await TVSystemSurfaceCoordinator.shared.invalidateUserScope()
    }

    private func invalidateLocalUsage() {
        let locations = TVLocalCacheLocations.live()
        try? CompanionSyncStore(documentURL: locations.companionDocumentURL).remove()
        try? TVSyncReceiptStore(receiptURL: locations.receiptURL).remove()
        try? CompanionCloudKitUserScopeStateStore(
            stateURL: locations.cloudKitUserScopeStateURL
        ).clear()
    }
}
