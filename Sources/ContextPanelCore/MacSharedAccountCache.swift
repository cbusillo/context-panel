import Foundation

/// A bounded, app-validated cache. It contains no credential/configuration material.
public struct MacSharedAccountCache: Sendable {
    public static let filename = "shared-account-observations.json"
    public let cacheURL: URL
    private struct Payload: Codable {
        let scope: CompanionCloudKitUserScope
        let checkedAt: Date
        let document: CompanionSyncDocument
    }
    public init(cacheURL: URL) { self.cacheURL = cacheURL }
    public func save(_ document: CompanionSyncDocument, verifiedScope: CompanionCloudKitUserScope, checkedAt: Date) throws {
        guard document.cloudKitUserScope == verifiedScope else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(scope: verifiedScope, checkedAt: checkedAt, document: document))
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)
    }
    public func load(now: Date) -> CompanionSyncDocument? {
        guard let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: cacheURL), data.count <= 8 * 1024 * 1024,
              let payload = try? JSONDecoder.contextPanelISO8601.decode(Payload.self, from: data),
              payload.document.cloudKitUserScope == payload.scope,
              payload.checkedAt <= now.addingTimeInterval(60),
              now.timeIntervalSince(payload.checkedAt) <= verifiedScopeLeaseSeconds else { return nil }
        return payload.document
    }
    public var verifiedScopeLeaseSeconds: TimeInterval {
        let settings = BackgroundRefreshSettingsStore(settingsURL: cacheURL.deletingLastPathComponent().appending(path: "background-refresh-settings.json")).load()
        return TimeInterval(settings.intervalSeconds + 10 * 60)
    }
    public func invalidate() {
        if FileManager.default.fileExists(atPath: cacheURL.path) { try? FileManager.default.removeItem(at: cacheURL) }
    }
}

public extension CompanionSyncDocument {
    /// Remote-only accounts need a supported current identity, not a legacy setup guess.
    func verifiedAccountsOnly() -> Self {
        let statuses = snapshot.providerStatuses.filter {
            $0.sharedAccountIdentity?.matches(provider: $0.provider, accountID: $0.companionAccountID) == true
                && ($0.sharedAccountIdentity?.userScope == nil || $0.sharedAccountIdentity?.userScope == cloudKitUserScope)
        }
        let keys = Set(statuses.map { $0.provider.rawValue + ":" + $0.companionAccountID })
        let displayIDs = Set(statuses.map { AccountDisplayMetadata.safeID($0.provider, $0.companionAccountID) })
        let filtered = CompanionSnapshot(generatedAt: snapshot.generatedAt, publishedAt: snapshot.publishedAt,
            limits: snapshot.limits.filter { keys.contains($0.provider.rawValue + ":" + $0.companionAccountID) },
            providerStatuses: statuses, promptCacheSummaries: [])
        return Self(snapshot: filtered, widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: [:], fastModeForecastSettings: fastModeForecastSettings,
            cloudKitUserScope: cloudKitUserScope,
            accountDisplayMetadata: accountDisplayMetadata?.filter { displayIDs.contains($0.id) },
            removedDisplayIDs: removedDisplayIDs, accountBurnRates: accountBurnRates,
            accountIdentityAliases: accountIdentityAliases, accountRemovalDates: accountRemovalDates, accountRestorationDates: accountRestorationDates)
    }
}

public enum MacSharedAccountPresentation {
    /// The account key a stored limit is presented under: its shared identity, else its companion identity.
    public static func accountKey(limit: UsageLimit, report: StoredProviderReport?,
                                  configuration: [LocalProviderAccountConfiguration], publisherID: String?) -> String {
        report?.sharedAccountIdentity?.accountID
            ?? CompanionLimit(limit: limit, identityConfiguredAccountID: AccountDisplayMetadata.companionIdentityOverride(
                provider: limit.provider, rawID: limit.accountID, configuredID: limit.configuredAccountID,
                configuration: configuration, publisherID: publisherID)).companionAccountID
    }

    public static func make(stored: StoredUsageSnapshot, configuration: [LocalProviderAccountConfiguration],
        publisherID: String? = nil, remote: CompanionSyncDocument? = nil,
        accountIntentDocument: AccountConfigurationDocument? = nil,
        now: Date, rates: [String: [String: ObservedBurnRate]] = [:],
        preferences: WidgetDisplayPreferences = .defaultPreferences,
        observedBurnRates: [String: ObservedBurnRate] = [:],
        stalenessPolicy: SnapshotStoreStalenessPolicy = SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.widgetMaximumAge),
        forecast: FastModeForecastSettings = .defaultSettings) -> WidgetSnapshot {
        let rejected = Set(stored.reports.filter { report in
            guard let bound = report.sharedAccountIdentity?.userScope, let scope = remote?.cloudKitUserScope else { return false }
            return bound != scope
        }.map { $0.provider.rawValue + ":" + $0.accountID })
        let stored = StoredUsageSnapshot(savedAt: stored.savedAt, snapshot: UsageSnapshot(generatedAt: stored.snapshot.generatedAt,
            limits: stored.snapshot.limits.filter { !rejected.contains($0.provider.rawValue + ":" + $0.accountID) }),
            reports: stored.reports.filter { !rejected.contains($0.provider.rawValue + ":" + $0.accountID) }, promptCacheObservations: stored.promptCacheObservations)
        let snapshot = CompanionSnapshot(storedSnapshot: stored, publishedAt: now,
            configuration: configuration, publisherID: publisherID)
        var transportedRates: [String: [String: ObservedBurnRate]] = [:]
        for local in stored.selectingSharedAccountObservations().snapshot.limits {
            guard let rate = rates[local.accountID]?[local.id], rate.sampleCount > 0 else { continue }
            let report = stored.reports.first { $0.provider == local.provider && $0.accountID == local.accountID }
            let key = accountKey(limit: local, report: report, configuration: configuration, publisherID: publisherID)
            guard let chosen = snapshot.limits.first(where: { $0.provider == local.provider && $0.companionAccountID == key
                && $0.label == local.label && $0.lastUpdatedAt == local.lastUpdatedAt && $0.used == local.used }) else { continue }
            let id = chosen.usageLimit.id
            transportedRates[key, default: [:]][id] = ObservedBurnRate(limitID: id,
                unitsPerHour: rate.unitsPerHour, observedDurationHours: rate.observedDurationHours, sampleCount: rate.sampleCount)
        }
        let intents = remote?.cloudKitUserScope == nil || remote?.cloudKitUserScope == accountIntentDocument?.removalUserScope ? accountIntentDocument : nil
        let knownDisplayIDs = Set(stored.reports.compactMap { report in report.sharedAccountIdentity.map { AccountDisplayMetadata.safeID(report.provider, $0.accountID) } })
        let pending = (accountIntentDocument?.pendingRemovedDisplayIDs ?? []).filter { knownDisplayIDs.contains($0) }
        let localRemovalIDs = Array(Set(intents?.globalRemovedDisplayIDs ?? []).union(pending)).sorted()
        let pendingDates = (accountIntentDocument?.removedDisplayDates ?? [:]).filter { pending.contains($0.key) }
        let localRemovalDates = (intents?.removedDisplayDates ?? [:]).merging(pendingDates) { max($0, $1) }
        let local = CompanionSyncDocument(snapshot: snapshot, widgetDisplayPreferences: preferences,
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: forecast, cloudKitUserScope: remote?.cloudKitUserScope,
            accountDisplayMetadata: AccountDisplayMetadata.companion(configuration: configuration, stored: stored,
                now: now, publisherID: publisherID).filteringSharedPresentationMetadata(stored: stored,
                    configuration: configuration, publisherID: publisherID),
            removedDisplayIDs: localRemovalIDs.isEmpty ? nil : localRemovalIDs, accountBurnRates: transportedRates,
            accountIdentityAliases: CompanionAccountIdentityAlias.verifiedAliases(stored: stored,
                configuration: configuration, publisherID: publisherID),
            accountRemovalDates: localRemovalDates.isEmpty ? nil : localRemovalDates, accountRestorationDates: intents?.restoredDisplayDates)
        let merged = local.mergingForRemotePublish(existing: remote?.verifiedAccountsOnly(), now: now)
        return WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: merged, status: .healthy), now: now, stalenessPolicy: stalenessPolicy)
    }
}
