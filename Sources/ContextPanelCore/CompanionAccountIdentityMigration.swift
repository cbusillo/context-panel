import Foundation

/// Retires only the legacy membership a connector has now authenticated.
/// It never reattributes old quota observations or acts as a removal decision.
public struct CompanionAccountIdentityAlias: Codable, Equatable, Sendable {
    public let provider: Provider
    public let legacyAccountID: String
    public let replacementAccountID: String
    public let configurationID: String
    public let observedAt: Date
    public let reusableIdentity: SharedProviderAccountIdentity?

    public static func verifiedAliases(stored: StoredUsageSnapshot, configuration: [LocalProviderAccountConfiguration],
        publisherID: String?) -> [Self] {
        stored.reports.flatMap { report -> [Self] in
            guard report.status != .failure, let identity = report.sharedAccountIdentity,
                  stored.snapshot.limits.contains(where: { $0.provider == report.provider && $0.accountID == report.accountID }),
                  let setup = configuration.first(where: { $0.matchesProviderReport(report) }) else { return [] }
            return Set([report.legacyAccountID, report.accountID].compactMap { $0 }).compactMap { raw -> Self? in
                let override = AccountDisplayMetadata.companionIdentityOverride(provider: report.provider,
                    rawID: raw, configuredID: report.configuredAccountID,
                    configuration: configuration, publisherID: publisherID)
                let legacy = CompanionLimit(limit: UsageLimit(provider: report.provider, accountID: raw,
                    configuredAccountID: report.configuredAccountID, accountName: "Account", label: "Identity",
                    unit: .percent, used: nil, limit: nil), identityConfiguredAccountID: override).companionAccountID
                guard legacy != identity.accountID else { return nil }
                return Self(provider: report.provider, legacyAccountID: legacy,
                    replacementAccountID: identity.accountID,
                    configurationID: AccountDisplayMetadata.companionConfigurationID(setup, publisherID: publisherID),
                    observedAt: report.generatedAt,
                    reusableIdentity: raw == report.accountID && raw.contains("-history-") ? identity.bound(toLocalAccountID: nil) : nil)
            }
        }
    }

    public var isValid: Bool {
        !legacyAccountID.isEmpty && !SharedProviderAccountIdentity.isSharedAccountID(legacyAccountID)
            && SharedProviderAccountIdentity.isSharedAccountID(replacementAccountID, provider: provider)
            && !configurationID.isEmpty
    }
}

public extension CompanionSyncDocument {
    func retiringLegacyMemberships(using aliases: [CompanionAccountIdentityAlias]) -> Self {
        let valid = aliases.filter(\.isValid)
        guard !valid.isEmpty else { return self }
        let retired = Set(valid.map { $0.provider.rawValue + ":" + $0.legacyAccountID })
        func keep(_ provider: Provider, _ id: String) -> Bool { !retired.contains(provider.rawValue + ":" + id) }
        func alias(_ provider: Provider, _ id: String) -> CompanionAccountIdentityAlias? {
            valid.first { $0.provider == provider && $0.legacyAccountID == id
                && $0.reusableIdentity?.matches(provider: provider, accountID: $0.replacementAccountID) == true
                && ($0.reusableIdentity?.userScope == nil || $0.reusableIdentity?.userScope == cloudKitUserScope) }
        }
        let filtered = CompanionSnapshot(generatedAt: snapshot.generatedAt, publishedAt: snapshot.publishedAt,
            limits: snapshot.limits.compactMap { limit -> CompanionLimit? in
                if let mapping = alias(limit.provider, limit.companionAccountID) {
                    return CompanionLimit(limit: limit.usageLimit.reidentified(accountID: mapping.replacementAccountID))
                }
                return keep(limit.provider, limit.companionAccountID) ? limit : nil
            },
            providerStatuses: snapshot.providerStatuses.compactMap { status -> CompanionProviderStatus? in
                if let mapping = alias(status.provider, status.companionAccountID), let identity = mapping.reusableIdentity {
                    let report = StoredProviderReport(provider: status.provider, accountID: mapping.replacementAccountID,
                        configuredAccountID: mapping.replacementAccountID, accountName: status.accountName,
                        generatedAt: status.generatedAt, resetCredits: status.resetCredits, status: status.status,
                        accessState: status.accessState, errorMessage: nil, sharedAccountIdentity: identity)
                    return CompanionProviderStatus(report: report)
                }
                return keep(status.provider, status.companionAccountID) ? status : nil
            }, promptCacheSummaries: snapshot.promptCacheSummaries.filter { keep($0.provider, $0.companionAccountID) })
        let retiredDisplayIDs = Set(valid.map { AccountDisplayMetadata.safeID($0.provider, $0.legacyAccountID) })
        return Self(snapshot: filtered, widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: observedBurnRates.filter { key, _ in
                let old = UsageSnapshot(generatedAt: snapshot.generatedAt, limits: snapshot.limits.map(\.usageLimit)).mainLimitSummaries.first { $0.id == key }
                let new = UsageSnapshot(generatedAt: filtered.generatedAt, limits: filtered.limits.map(\.usageLimit)).mainLimitSummaries.first { $0.id == key }
                return old != nil && Set(old!.liveLimits.map(\.id)) == Set(new?.liveLimits.map(\.id) ?? [])
            },
            fastModeForecastSettings: fastModeForecastSettings,
            accountRetentionStates: accountRetentionStates?.filter { keep($0.provider, $0.companionAccountID) },
            cloudKitUserScope: cloudKitUserScope,
            accountDisplayMetadata: accountDisplayMetadata?.compactMap { entry in
                if let mapping = valid.first(where: { $0.provider == entry.provider
                    && AccountDisplayMetadata.safeID($0.provider, $0.legacyAccountID) == entry.id
                    && $0.reusableIdentity != nil
                    && ($0.reusableIdentity?.userScope == nil || $0.reusableIdentity?.userScope == cloudKitUserScope) }) {
                    return AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(entry.provider, mapping.replacementAccountID),
                        configurationID: entry.configurationID, provider: entry.provider, label: entry.label,
                        isEnabled: entry.isEnabled, showInWidgets: entry.showInWidgets, useLast: entry.useLast,
                        sourceConfigured: entry.sourceConfigured, readState: entry.readState)
                }
                return retiredDisplayIDs.contains(entry.id) ? nil : entry
            },
            removedDisplayIDs: removedDisplayIDs,
            accountBurnRates: accountBurnRates.map { rates in
                var result = rates.filter { key, _ in !valid.contains { $0.legacyAccountID == key } }
                for old in snapshot.limits {
                    guard let mapping = alias(old.provider, old.companionAccountID),
                          let rate = rates[old.companionAccountID]?[old.usageLimit.id] else { continue }
                    let id = old.usageLimit.reidentified(accountID: mapping.replacementAccountID).id
                    result[mapping.replacementAccountID, default: [:]][id] = ObservedBurnRate(limitID: id,
                        unitsPerHour: rate.unitsPerHour, observedDurationHours: rate.observedDurationHours, sampleCount: rate.sampleCount)
                }
                return result
            },
            accountIdentityAliases: valid, accountRemovalDates: accountRemovalDates, accountRestorationDates: accountRestorationDates)
    }

    static func mergedIdentityAliases(_ a: [CompanionAccountIdentityAlias], _ b: [CompanionAccountIdentityAlias]) -> [CompanionAccountIdentityAlias] {
        var result: [String: CompanionAccountIdentityAlias] = [:]
        for alias in a + b where alias.isValid {
            let key = alias.provider.rawValue + ":" + alias.legacyAccountID
            if let previous = result[key], previous.observedAt >= alias.observedAt { continue }
            result[key] = alias
        }
        return result.values.sorted { ($0.provider.rawValue + $0.legacyAccountID) < ($1.provider.rawValue + $1.legacyAccountID) }
    }
}

public extension StoredUsageSnapshot {
    func selectingSharedAccountObservations() -> Self {
        var selected: [String: StoredProviderReport] = [:]
        for report in reports {
            let key = report.provider.rawValue + ":" + (report.sharedAccountIdentity?.accountID ?? report.accountID)
            if let old = selected[key] {
                let oldComplete = old.status != .failure && snapshot.limits.contains { $0.provider == old.provider && $0.accountID == old.accountID }
                let newComplete = report.status != .failure && snapshot.limits.contains { $0.provider == report.provider && $0.accountID == report.accountID }
                if oldComplete && !newComplete { continue }
                if oldComplete == newComplete && old.generatedAt >= report.generatedAt { continue }
            }
            selected[key] = report
        }
        let selectedKeys = Set(selected.values.map { $0.provider.rawValue + ":" + $0.accountID })
        let allKeys = Set(reports.map { $0.provider.rawValue + ":" + $0.accountID })
        return Self(savedAt: savedAt,
            snapshot: UsageSnapshot(generatedAt: snapshot.generatedAt, limits: snapshot.limits.filter {
                let key = $0.provider.rawValue + ":" + $0.accountID
                return !allKeys.contains(key) || selectedKeys.contains(key)
            }), reports: selected.values.sorted { ($0.provider.rawValue + $0.accountID) < ($1.provider.rawValue + $1.accountID) },
            promptCacheObservations: promptCacheObservations)
    }
}

public extension Array where Element == AccountDisplayMetadata {
    func filteringSharedPresentationMetadata(stored: StoredUsageSnapshot,
        configuration: [LocalProviderAccountConfiguration], publisherID: String?) -> Self {
        let winners = stored.selectingSharedAccountObservations().reports
        let preferred = Set(winners.compactMap { report -> String? in
            guard report.sharedAccountIdentity != nil,
                  let setup = configuration.first(where: { $0.matchesProviderReport(report) }) else { return nil }
            return AccountDisplayMetadata.companionConfigurationID(setup, publisherID: publisherID)
        })
        var seen = Set<String>()
        let ordered = filter { preferred.contains($0.configurationID) } + filter { !preferred.contains($0.configurationID) }
        let chosen = ordered.filter { seen.insert($0.id).inserted }
        let chosenIDs = Set(chosen.map { $0.configurationID + ":" + $0.id })
        return filter { chosenIDs.contains($0.configurationID + ":" + $0.id) }
    }
}

public extension UsageLimit {
    func reidentified(accountID: String, configuredAccountID: String? = nil) -> Self {
        Self(provider: provider, accountID: accountID, configuredAccountID: configuredAccountID ?? accountID,
            accountName: accountName, label: label, windowLabel: windowLabel, modelLabel: modelLabel,
            unit: unit, used: used, limit: limit, resetsAt: resetsAt, lastUpdatedAt: lastUpdatedAt,
            confidence: confidence, freshnessMode: freshnessMode, presentationAssumption: presentationAssumption,
            statusOverride: statusOverride, note: note)
    }
}
