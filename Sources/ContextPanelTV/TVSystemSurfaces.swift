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
}

actor TVSystemSurfaceCoordinator {
    static let shared = TVSystemSurfaceCoordinator()
    private static let logger = Logger(
        subsystem: "com.shinycomputers.contextpanel",
        category: "TVSystemSurfaces"
    )

    private let topShelfStore: TVTopShelfDocumentStore?
    private var contentSelection = TVSystemSurfaceContentSelection()
    private var updateTask: Task<TVSystemSurfaceUpdate, Never>?
    private var updateSequence = 0

    init(
        topShelfStore: TVTopShelfDocumentStore? = TVTopShelfSharedLocations.live().map {
            TVTopShelfDocumentStore(documentURL: $0.documentURL)
        }
    ) {
        self.topShelfStore = topShelfStore
    }

    func update(
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        version: TVCompanionSyncVersion?
    ) async -> TVSystemSurfaceUpdate {
        let selectedContent = contentSelection.select(
            snapshot: snapshot,
            preferences: preferences,
            version: version
        )
        let previousUpdateTask = updateTask
        updateSequence += 1
        let sequence = updateSequence
        let task = Task {
            _ = await previousUpdateTask?.value
            return await performUpdate(selectedContent)
        }
        updateTask = task
        let update = await task.value
        if updateSequence == sequence {
            updateTask = nil
        }
        return update
    }

    private func performUpdate(_ selectedContent: TVSystemSurfaceContent) async -> TVSystemSurfaceUpdate {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: TVPreferenceKeys.presentationMode)
            .flatMap(TVPresentationMode.init(rawValue:))
            ?? .fullDetail
        let now = Date()
        var notices: [String] = []
        if let topShelfStore {
            do {
                try topShelfStore.save(TVTopShelfDocument(
                    snapshot: selectedContent.snapshot,
                    preferences: selectedContent.preferences,
                    mode: mode,
                    now: now
                ))
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
}

@MainActor
final class ContextPanelTVAppDelegate: NSObject, UIApplicationDelegate {
    private static let retiredBadgeExpiryRequestIdentifier = "context-panel-provider-badge-expiry"
    private static let retiredProviderBadgesPreferenceKey = "tv-provider-badges-enabled"

    private let remoteStore = CompanionCloudKitSyncStoreFactory.make()
    private let notificationCenter = UNUserNotificationCenter.current()
    private var subscriptionRegistrationTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        clearRetiredProviderBadge()
        application.registerForRemoteNotifications()
        registerCloudKitSubscription()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        clearRetiredProviderBadge()
        application.registerForRemoteNotifications()
        registerCloudKitSubscription()
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
        Task { [remoteStore] in
            let currentUserRecordName: String?
            if notificationMetadata.subscriptionOwnerRecordName == nil {
                currentUserRecordName = nil
            } else {
                currentUserRecordName = try? await CKContainer(
                    identifier: ContextPanelLocations.iCloudContainerID
                ).userRecordID().recordName
            }
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
        }
    }

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

    private func clearRetiredProviderBadge() {
        UserDefaults.standard.removeObject(forKey: Self.retiredProviderBadgesPreferenceKey)
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [Self.retiredBadgeExpiryRequestIdentifier]
        )
        try? FileManager.default.removeItem(at: TVLocalCacheLocations.live().providerAlertStateURL)
        Task { [notificationCenter] in
            try? await notificationCenter.setBadgeCount(0)
        }
    }
}

private struct TVBackgroundSyncCoordinator: Sendable {
    let remoteStore: CompanionRemoteSyncStore

    func refresh() async -> UIBackgroundFetchResult {
        let startedAt = Date()
        guard let remoteLoad = await loadWithTimeout(now: startedAt) else { return .failed }
        let completedAt = Date()
        let loaded = remoteLoad.result
        guard let document = loaded.document else {
            return loaded.status == .failure ? .failed : .noData
        }

        let localLocations = TVLocalCacheLocations.live()
        let stalenessPolicy = SnapshotStoreStalenessPolicy.appDefault(
            maximumAge: SnapshotFreshness.companionProviderMaximumAge
        )
        let cacheSaveResult = CompanionSyncStore(
            documentURL: localLocations.companionDocumentURL
        ).saveResult(
            document,
            policy: stalenessPolicy,
            now: completedAt
        ) { currentResult in
            TVCompanionSyncCachePolicy.shouldKeepCurrent(
                currentResult,
                replacingWith: document
            )
        }
        let receiptStore = TVSyncReceiptStore(receiptURL: localLocations.receiptURL)
        let incomingVersion = TVCompanionSyncVersion(document: document)
        let publicationResult: CompanionSyncLoadResult
        let fetchResult: UIBackgroundFetchResult
        switch cacheSaveResult {
        case let .keptCurrent(currentResult):
            guard let currentDocument = currentResult.document else { return .failed }
            if TVCompanionSyncVersion(document: currentDocument) == incomingVersion {
                do {
                    try receiptStore.save(document: currentDocument, receivedAt: completedAt)
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
                    receivedAt: completedAt
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
            version: TVCompanionSyncVersion(document: publicationDocument)
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
}
